#!/bin/sh

LOG_FILE='/tmp/passwall-speedtest.log'
RESULT_DIR='/tmp/passwall-speedtest'
IP_FILE="$RESULT_DIR/result.csv"
IPV4_TXT='/usr/share/passwall-speedtest/ip.txt'
IPV6_TXT='/usr/share/passwall-speedtest/ipv6.txt'

SCRIPT_DIR='/usr/bin/passwall-speedtest'

function get_global_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get passwall-speedtest.global.$1`' 2>/dev/null
        shift
    done
}

function get_servers_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get passwall-speedtest.servers.$1`' 2>/dev/null
        shift
    done
}

echolog() {
    local d="$(date "+%Y-%m-%d %H:%M:%S")"
    echo -e "$d: $*"
    echo -e "$d: $*" >>$LOG_FILE
}

function read_config(){
    get_global_config "enabled" "custom_cron_enabled" "custom_cron" "tl" "tll" "tlr" "ip_source" "custom_ip_file" "custom_allip" "ip_online_url" "ip_online_regions" "node_test_node" "node_test_url" "node_test_count" "node_test_timeout" "node_test_probes" "node_test_threads"
    get_servers_config "ssr_services" "ssr_enabled" "passwall_enabled" "passwall_services" "passwall2_enabled" "passwall2_services" "bypass_enabled" "bypass_services" "vssr_enabled" "vssr_services" "DNS_enabled" "AliDNS_ip_count" "HOST_enabled" "MosDNS_enabled" "MosDNS_ip_count" "openclash_restart" "AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin"
}

function rotate_result_files(){
    # 滚动保存result.csv文件，最多保存10个版本
    if [ -f "$IP_FILE" ]; then
        # 删除最旧的文件 (.9)
        [ -f "${IP_FILE}.9" ] && rm -f "${IP_FILE}.9"

        # 从.8到.1逐级重命名
        for i in 8 7 6 5 4 3 2 1; do
            if [ -f "${IP_FILE}.$i" ]; then
                mv "${IP_FILE}.$i" "${IP_FILE}.$((i+1))"
            fi
        done

        # 将当前的result.csv重命名为result.csv.1
        mv "$IP_FILE" "${IP_FILE}.1"
    fi
}

function first_result_ip(){
    sed -n '2,$p' "$1" 2>/dev/null | grep -v '^#' | awk -F, 'NF >= 7 && $1 != "" { print $1; exit }'
}

# 按延迟升序排序结果数据行，表头保留在首行。
# 兼容测速被中断、二进制未完成最终排序的情况，保证最快 IP 位于首行。
# 第二参数 mode=latency 时（走节点测速模式，下载列恒 0.00）仅按延迟升序排。
# 用 awk 自实现排序，不依赖 sort 的 -k/-n 浮点修饰符（某些 busybox sort 会忽略 -k 键
# 退化为整行字典序，导致选错最优 IP）。
function sort_result(){
    local file="$1"
    local mode="${2:-}"
    [ -s "$file" ] || return 0
    local header
    header=$(sed -n '1p' "$file" 2>/dev/null)
    {
        [ -n "$header" ] && echo "$header"
        sed '1d' "$file" 2>/dev/null | grep -v '^#' | \
        awk -F, -v mode="$mode" '
            { dl[NR]=($6=="")?0:($6+0); lat[NR]=($5=="")?0:($5+0); line[NR]=$0 }
            END {
                n=NR
                for (i=2;i<=n;i++) {
                    dk=dl[i]; lk=lat[i]; b=line[i]; j=i-1
                    while (j>=1 && cmp(dk,lk,dl[j],lat[j],mode)) { dl[j+1]=dl[j]; lat[j+1]=lat[j]; line[j+1]=line[j]; j-- }
                    dl[j+1]=dk; lat[j+1]=lk; line[j+1]=b
                }
                for (i=1;i<=n;i++) print line[i]
            }
            function cmp(dk,lk,dj,lj,mode) {
                if (mode=="latency") return (lk<lj)
                if (dk!=dj) return (dk>dj)
                return (lk<lj)
            }'
    } > "${file}.sorted" 2>/dev/null
    [ -s "${file}.sorted" ] && mv -f "${file}.sorted" "$file" || rm -f "${file}.sorted"
}

# 从在线 CM 源下载候选 IP 列表。源格式: IP:PORT#国家码 (如 1.2.3.4:443#JP)
# 只保留 :443 行；若 ip_online_regions 非空则按国家码白名单过滤(空格/逗号分隔,留空=全量 :443)；
# 去端口去重,只留纯 IP,写入 RESULT_DIR/ip_online.txt 并 echo 该路径。
# 带下载重试、空检查、行数下限、格式校验(参考仓库根 update_cf_ip.sh)。
function fetch_online_ip_file(){
    local src="${ip_online_url:-https://zip.cm.edu.kg/all.txt}"
    local regions="${ip_online_regions:-}"
    local timeout=30
    local min_lines="${CF_MIN_LINES:-50}"
    local out="${RESULT_DIR}/ip_online.txt"
    local tmp
    tmp="$(mktemp "${RESULT_DIR}/ip_online.XXXXXX")" || { echolog "创建在线 IP 临时文件失败"; return 1; }

    echolog "下载在线 IP 列表: $src (地区过滤: ${regions:-全量 :443})"
    local ok=0 i
    for i in 1 2 3; do
        if curl -fsSL --max-time "$timeout" -o "$tmp" "$src" 2>/dev/null; then ok=1; break; fi
        [ "$i" = 3 ] || echolog "下载失败(第 $i 次),重试..."
    done
    [ "$ok" = 1 ] || { echolog "下载失败(重试 3 次): $src"; rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { echolog "下载内容为空"; rm -f "$tmp"; return 1; }

    # 只保留 :443 行;可选国家码白名单过滤;去端口去重,只留纯 IP
    if [ -n "$regions" ]; then
        local re
        re=$(printf '%s' "$regions" | sed 's/[[:space:],]/|/g')
        { grep ':443#' "$tmp" | grep -E ":443#($re)$" | sed 's/:.*//' | sort -u || true; } > "${tmp}.new"
    else
        { grep ':443#' "$tmp" | sed 's/:.*//' | sort -u || true; } > "${tmp}.new"
    fi
    mv -f "${tmp}.new" "$tmp"

    local lines good
    lines=$(wc -l < "$tmp" | tr -d ' ')
    if [ "$lines" -lt "$min_lines" ]; then
        echolog "在线 IP 行数过少 ($lines < $min_lines),疑似源异常,中止"
        rm -f "$tmp"; return 1
    fi
    good=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$tmp" || true)
    if [ "$good" -lt $((lines * 9 / 10)) ]; then
        echolog "在线 IP 格式异常,合法行 $good/$lines 不足 90%,中止"
        rm -f "$tmp"; return 1
    fi

    mkdir -p "$RESULT_DIR"
    mv -f "$tmp" "$out"
    echolog "在线 IP 列表就绪: $lines 行 -> $out"
    echo "$out"
}

function select_ip_file(){
    case "${ip_source:-}" in
        online)
            fetch_online_ip_file
            ;;
        builtin_ipv4)
            echo "$IPV4_TXT"
            ;;
        builtin_ipv6)
            echo "$IPV6_TXT"
            ;;
        custom_file)
            if [ -n "${custom_ip_file:-}" ]; then
                echo "$custom_ip_file"
            else
                echolog "Custom IP list file is empty, fallback to built-in IPv4 list" >/dev/null
                echo "$IPV4_TXT"
            fi
            ;;
        "")
            echo "$IPV4_TXT"
            ;;
        *)
            echolog "Unknown IP list source: ${ip_source}, fallback to built-in IPv4 list" >/dev/null
            echo "$IPV4_TXT"
            ;;
    esac
}

function speed_test(){
    # 走节点测速：把候选 CF IP 写进 passwall 节点 address，用 passwall app.sh run_socks
    # 拉本地 SOCKS，curl -I 取 time_pretransfer 测延迟，多 worker 并行、多 probe fail-fast。
    # 结果写回各 passwall worker 节点。
    node_speed_test
    return $?
}

# ── 走节点测速 ──────────────────────────────────────────────
# 把每个候选 CF IP 临时写进一个 passwall 节点的 address，再用 passwall 式
# URL 测速（拉起该节点本地 SOCKS → curl -I 探测 → 取 time_pretransfer 得毫秒）
# 按延迟选最优 IP，测完把最优 IP 留在该节点 address。只测延迟，不测下载带宽。
#
# 多线程：若第三方设置里选了 passwall 节点（passwall_services），这些真节点作并行 worker，
# 每个 worker 通过自己的链路测全部候选 IP、各写各的真最优；并发上限 node_test_threads。
# 不克隆节点（历史 temp-clone 方案因 clone 漏 SNI/Host 字段导致探测全失败已废弃）。
# uci set/commit 经 mkdir 原子锁串行化（多进程并发改 /tmp/.uci/passwall staging 会丢更新）。
NODE_TEST_FLAG_BASE=""
NODE_TEST_NODE=""
NODE_TEST_ORIG_ADDR=""
NODE_TEST_DONE=0
NT_LOCKDIR=""
NT_ORIG_FILE=""

node_test_cleanup() {
    [ "${NODE_TEST_CLEANED:-0}" = "1" ] && return
    NODE_TEST_CLEANED=1
    # 杀本次拉起的临时 SOCKS 进程（按 flag 前缀通配，匹配单节点 + 各多线程 worker，排除脚本自身）
    if [ -n "${NODE_TEST_FLAG_BASE}" ]; then
        local pid_file
        for pid_file in /tmp/etc/passwall/*"${NODE_TEST_FLAG_BASE}"*_plugin.pid; do
            [ -s "$pid_file" ] && kill -9 "$(head -n1 "$pid_file")" >/dev/null 2>&1
        done
        busybox pgrep -af "${NODE_TEST_FLAG_BASE}" 2>/dev/null | awk '! /passwall-speedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${NODE_TEST_FLAG_BASE}"* 2>/dev/null
    fi
    rmdir "${NT_LOCKDIR}" 2>/dev/null
    # 未正常完成时恢复节点 address：多线程从映射文件恢复所有 worker，单节点恢复 NODE_TEST_NODE
    if [ "${NODE_TEST_DONE:-0}" != "1" ]; then
        if [ -n "${NT_ORIG_FILE}" ] && [ -f "${NT_ORIG_FILE}" ]; then
            local idx w orig
            while read -r idx w orig; do
                [ -n "$w" ] || continue
                uci set passwall.${w}.address="${orig}"
            done < "${NT_ORIG_FILE}"
            uci commit passwall
            echolog "走节点测速被中断或失败，已按映射文件恢复所有 worker 节点原 address"
        elif [ -n "${NODE_TEST_NODE}" ] && [ -n "${NODE_TEST_ORIG_ADDR}" ]; then
            uci set passwall.${NODE_TEST_NODE}.address="${NODE_TEST_ORIG_ADDR}"
            uci commit passwall
            echolog "走节点测速被中断或失败，已恢复节点 ${NODE_TEST_NODE} 原 address"
        fi
    fi
    rm -f "${NT_ORIG_FILE}" 2>/dev/null
}

nt_lock_acquire() { while ! mkdir "${NT_LOCKDIR}" 2>/dev/null; do sleep 0.1; done; }
nt_lock_release() { rmdir "${NT_LOCKDIR}" 2>/dev/null; }

# 单个 worker：通过节点 $2 的链路测全部候选 IP（$5），保留行写入结果文件 $4。
# ash 子 shell 里 local 可用（已验证）。uci set+commit 经锁串行化；run_socks+探测在锁外并行。
# 参数: $1=idx $2=node $3=origaddr $4=result_file $5=ip_list $6=probe_url $7=timeout $8=probes $9=socks_port $10=flag
node_test_worker() {
    local _idx=$1 _W=$2 _orig=$3 _rfile=$4 _ips=$5 _purl=$6 _tmo=$7 _probes=$8 _port=$9 _flag=${10}
    local _ip _idx2=0 _total
    _total=$(printf '%s\n' "$_ips" | grep -c .)
    echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$_rfile"
    printf '%s\n' "$_ips" | while read -r _ip; do
        [ -n "$_ip" ] || continue
        _idx2=$((_idx2 + 1))
        # uci set+commit 加锁（防多 worker 并发改 staging 丢更新）
        nt_lock_acquire
        uci set passwall.${_W}.address="${_ip}"
        uci commit passwall
        nt_lock_release
        # 拉本地 SOCKS
        NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
            flag="${_flag}" node=${_W} \
            bind=127.0.0.1 socks_port=${_port} \
            config_file=${_flag}.json >>$LOG_FILE 2>&1
        # 就绪轮询 + 多探测（任一次非成功即 fail=1 并跳出，该 IP 整体丢弃）
        local _sent=0 _recv=0 _lat="" _done=0 _notready=0 _fail=0
        while [ $_done -lt $_probes ]; do
            local _res _code _tpre _rc
            _res=$(curl -x socks5h://127.0.0.1:${_port} -I -skL \
                --connect-timeout 3 --max-time ${_tmo} \
                -o /dev/null -w "%{http_code}:%{time_pretransfer}" "${_purl}" 2>/dev/null)
            _rc=$?
            if [ $_rc -eq 7 ]; then
                _notready=$((_notready + 1))
                [ $_notready -ge 10 ] && break
                sleep 0.3
                continue
            fi
            _notready=0
            _sent=$((_sent + 1))
            _done=$((_done + 1))
            _code="${_res%%:*}"
            _tpre="${_res##*:}"
            case "$_code" in
                200|204|301|302|307|308|40[0-9])
                    _recv=$((_recv + 1))
                    _lat="${_lat} ${_tpre}"
                    ;;
                *)
                    _fail=1
                    break
                    ;;
            esac
        done
        # 清理本次 SOCKS
        local _pf
        for _pf in /tmp/etc/passwall/*"${_flag}"*_plugin.pid; do
            [ -s "$_pf" ] && kill -9 "$(head -n1 "$_pf")" >/dev/null 2>&1
        done
        busybox pgrep -af "${_flag}" 2>/dev/null | awk '! /passwall-speedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${_flag}"* 2>/dev/null
        # 均值/丢包
        local _avg=0 _loss="1.00"
        if [ $_recv -gt 0 ]; then
            _loss=$(awk -v s=$_sent -v r=$_recv 'BEGIN{printf "%.2f", (s-r)/s}')
            _avg=$(echo "$_lat" | tr ' ' '\n' | grep -E '^[0-9.]+$' | awk '{s+=$1; n++} END{ if(n>0) printf "%.2f", s/n*1000 }')
            [ -z "$_avg" ] && _avg=0
        fi
        # 过滤：任一次失败/未完成即丢；否则按 tl/tll/tlr
        local _keep=1
        if [ $_fail -eq 1 ] || [ $_recv -lt $_probes ]; then
            _keep=0
        else
            if [ -n "${tl:-}" ] && [ "${tl}" -gt 0 ] 2>/dev/null; then
                [ "$(awk -v v=$_avg -v c=$tl 'BEGIN{print (v>c)?1:0}')" = "1" ] && _keep=0
            fi
            if [ -n "${tll:-}" ] && [ "${tll}" -gt 0 ] 2>/dev/null; then
                [ "$(awk -v v=$_avg -v c=$tll 'BEGIN{print (v<c)?1:0}')" = "1" ] && _keep=0
            fi
            if [ -n "${tlr:-}" ]; then
                [ "$(awk -v v=$_loss -v c=$tlr 'BEGIN{print (v>c)?1:0}')" = "1" ] && _keep=0
            fi
        fi
        if [ $_keep -eq 1 ]; then
            echo "${_ip},${_sent},${_recv},${_loss},${_avg},0.00," >> "$_rfile"
        fi
        local _st
        _st=$([ $_keep -eq 1 ] && echo "保留" || echo "丢弃")
        echolog "进度: 走节点测速 [${_W}] ${_idx2}/${_total} ($((_idx2*100/_total))%) - ${_ip} 延迟 ${_avg}ms 丢包 ${_loss} [${_st}]"
    done
    # 本 worker 结果按延迟升序排（首行即该节点最优）
    sort_result "$_rfile" latency
}

node_speed_test() {
    # 校验 passwall 已安装
    [ -f /usr/share/passwall/app.sh ] || { echolog "未安装 passwall，无法使用走节点测速"; return 1; }
    [ -f /usr/share/passwall/utils.sh ] || { echolog "缺少 passwall utils.sh，无法使用走节点测速"; return 1; }
    # passwall 的 utils.sh 会覆盖 LOG_FILE 与 echolog()，先保存再恢复，避免日志写进 passwall 的日志文件
    local _pws_log_file="$LOG_FILE"
    . /usr/share/passwall/utils.sh
    LOG_FILE="$_pws_log_file"
    echolog() {
        local d="$(date "+%Y-%m-%d %H:%M:%S")"
        echo -e "$d: $*"
        echo -e "$d: $*" >>$LOG_FILE
    }

    rm -rf $LOG_FILE
    mkdir -p "$RESULT_DIR"

    # 公共参数
    local probe_url="${node_test_url:-https://www.google.com/generate_204}"
    local timeout="${node_test_timeout:-5}"
    case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
    local probes="${node_test_probes:-3}"
    case "$probes" in ''|*[!0-9]*) probes=3 ;; esac
    [ "$probes" -ge 1 ] 2>/dev/null || probes=3
    [ "$probes" -le 5 ] 2>/dev/null || probes=5
    local threads="${node_test_threads:-5}"
    case "$threads" in ''|*[!0-9]*) threads=5 ;; esac
    [ "$threads" -ge 0 ] 2>/dev/null || threads=5

    local selected_ip_file
    selected_ip_file="$(select_ip_file)"
    [ -f "$selected_ip_file" ] || { echolog "候选 IP 列表文件不存在: $selected_ip_file"; return 1; }
    local count="${node_test_count:-30}"
    case "$count" in ''|*[!0-9]*) count=30 ;; esac
    [ "$count" -gt 0 ] || count=30
    local ip_list total
    ip_list=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$selected_ip_file" | head -n "$count")
    total=$(echo "$ip_list" | grep -c .)
    [ "$total" -gt 0 ] || { echolog "候选 IP 列表为空"; return 1; }

    NODE_TEST_FLAG_BASE="node_test_$$"
    NODE_TEST_DONE=0
    NODE_TEST_CLEANED=0
    trap node_test_cleanup EXIT INT TERM

    # ── 检测 worker：第三方设置里选的 passwall 节点 ──
    local workers_raw=""
    if [ "x${passwall_enabled:-0}" = "x1" ] && [ -n "${passwall_services:-}" ]; then
        local _w _seen=""
        for _w in ${passwall_services}; do
            case " $_seen " in *" $_w "*) ;; *) _seen="$_seen $_w"; workers_raw="$workers_raw $_w"; ;; esac
        done
    fi

    if [ -n "$workers_raw" ]; then
        # ── 多节点并行路径 ──
        # 校验每个 worker，建 idx→node→origaddr 映射文件
        NT_ORIG_FILE="$(mktemp "${RESULT_DIR}/node_test_orig.XXXXXX")" || { echolog "创建 worker 映射文件失败"; return 1; }
        NT_LOCKDIR="${RESULT_DIR}/.node_test_lock"
        local valid_workers="" widx=0
        for _w in $workers_raw; do
            local wt wa
            wt=$(echo $(config_n_get $_w type) | tr 'A-Z' 'a-z')
            [ -n "$wt" ] || { echolog "worker 节点 $_w 不存在或无 type，跳过"; continue; }
            if [ "$wt" = "socks" ]; then
                echolog "worker 节点 $_w 是 SOCKS 类型，跳过（其 address 即 SOCKS 服务器，替换为 CF IP 会失效）"
                continue
            fi
            wa=$(config_n_get $_w address)
            [ -n "$wa" ] || { echolog "worker 节点 $_w 未配置 address，跳过"; continue; }
            widx=$((widx + 1))
            printf '%s\t%s\t%s\n' "$widx" "$_w" "$wa" >> "$NT_ORIG_FILE"
            valid_workers="$valid_workers $_w"
        done
        if [ -z "$valid_workers" ]; then
            echolog "第三方设置里的 passwall 节点均不可用，回退单节点串行"
            rm -f "$NT_ORIG_FILE"; NT_ORIG_FILE=""
        else
            echolog "开始走节点测速（多节点并行: ${widx} 个 worker, 候选: ${total}, 每IP探测 ${probes} 次, 超时 ${timeout}s, 并发上限 ${threads}）"
            echolog "提示：测速期间所有 worker 节点的 address 会被反复改写，这些节点会短暂抖动，测完各写各的最优 IP"
            # 分批并行：每批 threads 个 worker，批内 background、批间 wait
            local launched=0 batch
            [ "$threads" -ge 1 ] 2>/dev/null || threads=$widx
            for _w in $valid_workers; do
                launched=$((launched + 1))
                local _rfile="${RESULT_DIR}/result.csv.tmp.$_w"
                # 端口确定性分配：48900 + idx - 1（每 worker 固定端口，复用于其所有 IP）
                local _port=$((48900 + launched - 1))
                node_test_worker "$launched" "$_w" "" "$_rfile" "$ip_list" "$probe_url" "$timeout" "$probes" "$_port" "${NODE_TEST_FLAG_BASE}_$launched" &
                # 每 threads 个或最后一个，等本批完成
                batch=$((launched % threads))
                if [ "$batch" -eq 0 ] || [ "$launched" -ge "$widx" ]; then
                    wait
                fi
            done
            # 各 worker 写回各自最优（串行，单进程无锁）
            local merged="$(mktemp "${RESULT_DIR}/result.csv.merged.XXXXXX")"
            echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$merged"
            local mi mw morig mwfile mwbest
            while read -r mi mw morig; do
                [ -n "$mw" ] || continue
                mwfile="${RESULT_DIR}/result.csv.tmp.$mw"
                mwbest=$(first_result_ip "$mwfile")
                if [ -n "$mwbest" ]; then
                    uci set passwall.${mw}.address="${mwbest}"
                    echolog "走节点测速完成 [${mw}]，最优 IP ${mwbest} 已写入 passwall 节点 ${mw}"
                else
                    uci set passwall.${mw}.address="${morig}"
                    echolog "走节点测速 [${mw}] 结果为空，恢复原 address"
                fi
                sed '1d' "$mwfile" 2>/dev/null >> "$merged"
                rm -f "$mwfile"
            done < "$NT_ORIG_FILE"
            uci commit passwall
            rm -f "$NT_ORIG_FILE"; NT_ORIG_FILE=""
            # 合并结果按延迟升序排，供 UI/图表展示（首行=全局最低延迟，供 DNS/host 用）
            sort_result "$merged" latency
            if [ -z "$(first_result_ip "$merged")" ]; then
                echolog "走节点测速所有 worker 结果均为空，保留上一次结果"
                rm -f "$merged"
                NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
                return 1
            fi
            echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$merged"
            rotate_result_files
            mv -f "$merged" "$IP_FILE"
            bestip=$(first_result_ip "$IP_FILE")
            [ -n "$bestip" ] && echolog "走节点测速全部完成，全局最低延迟 IP ${bestip}（已写入各 worker 节点）"
            NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
            return 0
        fi
    fi

    # ── 单节点串行路径（无第三方 passwall worker 时回退）──
    NODE_TEST_NODE="${node_test_node:-}"
    [ -n "${NODE_TEST_NODE}" ] || { echolog "未选择 passwall 节点，无法走节点测速"; return 1; }
    local node_type
    node_type=$(echo $(config_n_get ${NODE_TEST_NODE} type) | tr 'A-Z' 'a-z')
    [ -n "${node_type}" ] || { echolog "passwall 节点 ${NODE_TEST_NODE} 不存在或无 type"; return 1; }
    if [ "${node_type}" = "socks" ]; then
        echolog "走节点测速不支持 SOCKS 类型的 passwall 节点（其 address 即 SOCKS 服务器，替换为 CF IP 会失效），请选择一个 CF-CDN 前置的代理节点"
        return 1
    fi
    NODE_TEST_ORIG_ADDR=$(config_n_get ${NODE_TEST_NODE} address)
    [ -n "${NODE_TEST_ORIG_ADDR}" ] || { echolog "passwall 节点 ${NODE_TEST_NODE} 未配置 address"; return 1; }

    echolog "开始走节点测速（单节点串行: ${NODE_TEST_NODE}, 候选: ${total}, 每IP探测 ${probes} 次, 超时 ${timeout}s）"
    echolog "提示：测速期间源节点 ${NODE_TEST_NODE} 的 address 会被反复改写，该节点会短暂抖动，测完写回最优 IP"

    result_tmp="$(mktemp "${RESULT_DIR}/result.csv.tmp.XXXXXX")" || { echolog "创建临时测速结果文件失败"; return 1; }
    # 单节点：inline 调用 worker（不 background），端口 48900、flag=base
    node_test_worker 1 "${NODE_TEST_NODE}" "${NODE_TEST_ORIG_ADDR}" "$result_tmp" "$ip_list" "$probe_url" "$timeout" "$probes" 48900 "${NODE_TEST_FLAG_BASE}"

    if [ -z "$(first_result_ip "$result_tmp")" ]; then
        echolog "走节点测速结果 IP 数量为 0，恢复源节点原 address 并保留上一次结果"
        rm -f "$result_tmp"
        uci set passwall.${NODE_TEST_NODE}.address="${NODE_TEST_ORIG_ADDR}"
        uci commit passwall
        NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
        return 1
    fi

    echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$result_tmp"
    rotate_result_files
    mv -f "$result_tmp" "$IP_FILE"

    bestip=$(first_result_ip "$IP_FILE")
    if [ -n "${bestip}" ]; then
        uci set passwall.${NODE_TEST_NODE}.address="${bestip}"
        uci commit passwall
        echolog "走节点测速完成，最优 IP ${bestip} 已写入 passwall 节点 ${NODE_TEST_NODE}"
    fi

    NODE_TEST_DONE=1; node_test_cleanup; trap - EXIT INT TERM
    return 0
}

function ip_replace(){

    # 获取最快 IP（从 result.csv 结果文件中获取第一个 IP）
    bestip=$(first_result_ip "$IP_FILE")
    if [[ -z "${bestip}" ]]; then
        echolog "走节点测速结果 IP 数量为 0,跳过下面步骤..."
    else
        host_ip
        mosdns_ip
        astra_dns_ip
        alidns_ip
        ssr_best_ip
        vssr_best_ip
        bypass_best_ip
        passwall_best_ip
        passwall2_best_ip
    fi
}

function host_ip() {
    if [ "x${HOST_enabled}" == "x1" ] ;then
        get_servers_config "host_domain"
        HOSTS_LINE=$(echo "$host_domain" | sed 's/,/ /g' | sed "s/^/$bestip /g")
        host_domain_first=$(echo "$host_domain" | awk -F, '{print $1}')

        if [ -n "$(grep $host_domain_first /etc/hosts)" ]
        then
            echo $host_domain_first
            sed -i".bak" "/$host_domain_first/d" /etc/hosts
            echo $HOSTS_LINE >> /etc/hosts;
        else
            echo $HOSTS_LINE >> /etc/hosts;
        fi
        /etc/init.d/dnsmasq reload &>/dev/null
        echolog "HOST 完成"
    fi
}

function mosdns_ip() {
    if [ "x${MosDNS_enabled}" == "x1" ] ;then
        # 默认只取1个，除非配置了 MosDNS_ip_count
        count=1
        if [ -n "$MosDNS_ip_count" ] && [ "$MosDNS_ip_count" -gt 1 ]; then
            count=$MosDNS_ip_count
        fi

        # 获取前 count 个 IP，注意结果文件的第一行通常是标题，所以从第2行开始取
        # sed -n "2,$((count + 1))p" 取第2行到第 count+1 行
        # grep -v '^#' 排除注释行（如末尾的时间戳）
        # awk -F, '{print $1}' 提取第一列 IP
        # tr '\n' ' ' 将多行转为空格分隔的一行
        bestips=$(sed -n "2,$((count + 1))p" $IP_FILE | grep -v '^#' | awk -F, '{print $1}' | tr '\n' ' ')

        if [ -n "$(grep 'option cloudflare' /etc/config/mosdns)" ]
        then
            sed -i".bak" "/option cloudflare/d" /etc/config/mosdns
        fi
        if [ -n "$(grep 'list cloudflare_ip' /etc/config/mosdns)" ]
        then
            sed -i".bak" "/list cloudflare_ip/d" /etc/config/mosdns
        fi

        # 写入 option cloudflare '1'
        sed -i '/^$/d' /etc/config/mosdns && echo -e "\toption cloudflare '1'" >> /etc/config/mosdns

        # 循环写入所有 IP
        for ip in $bestips; do
            if [ -n "$ip" ]; then
                 echo -e "\tlist cloudflare_ip '$ip'" >> /etc/config/mosdns
            fi
        done

        /etc/init.d/mosdns restart &>/dev/null
        if [ "x${openclash_restart}" == "x1" ] ;then
            /etc/init.d/openclash restart &>/dev/null
        fi
        echolog "MosDNS 写入完成，已写入IP: $bestips"
    fi
}

function astra_dns_ip() {
    if [ "x${AstraDNS_enabled}" == "x1" ] ;then
        astra_config="${AstraDNS_config:-/etc/astra-dns/named.yaml}"
        astra_bin="${AstraDNS_bin:-/usr/bin/astra-dns}"

        if [ ! -x ${SCRIPT_DIR}/astra-dns.sh ]; then
            echolog "astra-dns 写入失败: ${SCRIPT_DIR}/astra-dns.sh 不存在"
            return 1
        fi

        if ${SCRIPT_DIR}/astra-dns.sh --result-csv "$IP_FILE" --config "$astra_config" --bin "$astra_bin" >>$LOG_FILE 2>&1; then
            echolog "astra-dns 写入完成，配置文件: $astra_config"
        else
            echolog "astra-dns 写入失败，请检查配置文件路径、二进制路径和 YAML 格式"
            return 1
        fi
    fi
}

function passwall_best_ip(){
    if [ "x${passwall_enabled}" == "x1" ] ;then
        echolog "设置passwall IP"
        for ssrname in $passwall_services
        do
            echo $ssrname
            uci set passwall.$ssrname.address="${bestip}"
        done
        uci commit passwall
    fi
}

function passwall2_best_ip(){
    if [ "x${passwall2_enabled}" == "x1" ] ;then
        echolog "设置passwall2 IP"
        for ssrname in $passwall2_services
        do
            echo $ssrname
            uci set passwall2.$ssrname.address="${bestip}"
        done
        uci commit passwall2
    fi
}

function ssr_best_ip(){
    if [ "x${ssr_enabled}" == "x1" ] ;then
        echolog "设置ssr IP"
        for ssrname in $ssr_services
        do
            echo $ssrname
            uci set shadowsocksr.$ssrname.server="${bestip}"
            uci set shadowsocksr.$ssrname.ip="${bestip}"
        done
        uci commit shadowsocksr
    fi
}

function vssr_best_ip(){
    if [ "x${vssr_enabled}" == "x1" ] ;then
        echolog "设置Vssr IP"
        for ssrname in $vssr_services
        do
            echo $ssrname
            uci set vssr.$ssrname.server="${bestip}"
        done
        uci commit vssr
    fi
}

function bypass_best_ip(){
    if [ "x${bypass_enabled}" == "x1" ] ;then
        echolog "设置Bypass IP"
        for ssrname in $bypass_services
        do
            echo $ssrname
            uci set bypass.$ssrname.server="${bestip}"
        done
        uci commit bypass
    fi
}

function alidns_ip(){
    if [ "x${DNS_enabled}" == "x1" ] ;then
        get_servers_config "DNS_type" "app_key" "app_secret" "main_domain" "sub_domain" "line" "AliDNS_ip_count"
        if [ "x${DNS_type}" == "xaliyun" ] ;then
            count=1
            case "$AliDNS_ip_count" in
                ''|*[!0-9]*) count=1 ;;
                *) [ "$AliDNS_ip_count" -gt 1 ] && count=$AliDNS_ip_count ;;
            esac

            bestips=$(sed -n "2,$((count + 1))p" $IP_FILE | grep -v '^#' | awk -F, '{print $1}' | sed '/^$/d' | tr '\n' ' ')
            first_dns_ip=$(echo "$bestips" | awk '{print $1}')
            case "$first_dns_ip" in
                *:*) bestip_is_ipv6=1 ;;
                *) bestip_is_ipv6=0 ;;
            esac

            if [ -z "$bestips" ]; then
                echolog "阿里云DNS写入失败: 未找到可写入IP"
                return
            fi

            for sub in $sub_domain
            do
                if ${SCRIPT_DIR}/aliddns.sh "$app_key" "$app_secret" "$main_domain" "$sub" "$line" "$bestip_is_ipv6" $bestips; then
                    echolog "更新域名${sub}阿里云DNS完成，已写入IP: $bestips"
                else
                    echolog "更新域名${sub}阿里云DNS失败，请检查上方阿里云API错误信息"
                fi
                sleep 1s
            done
        fi
        echo "aliyun done"
    fi
}

read_config

# 启动参数
if [ "$1" ] ;then
    [ $1 == "start" ] && speed_test && ip_replace
    [ $1 == "test" ] && speed_test
    [ $1 == "replace" ] && ip_replace
    exit
fi