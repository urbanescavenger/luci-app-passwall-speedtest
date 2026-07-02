#!/bin/sh

LOG_FILE='/tmp/cloudflarespeedtest.log'
RESULT_DIR='/tmp/CloudflareSpeedTest'
IP_FILE="$RESULT_DIR/result.csv"
IPV4_TXT='/usr/share/CloudflareSpeedTest/ip.txt'
IPV6_TXT='/usr/share/CloudflareSpeedTest/ipv6.txt'

function get_global_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cloudflarespeedtest.global.$1`' 2>/dev/null
        shift
    done
}

function get_servers_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cloudflarespeedtest.servers.$1`' 2>/dev/null
        shift
    done
}

echolog() {
    local d="$(date "+%Y-%m-%d %H:%M:%S")"
    echo -e "$d: $*"
    echo -e "$d: $*" >>$LOG_FILE
}

function read_config(){
    get_global_config "enabled" "speed_limit" "custom_url" "threads" "custom_cron_enabled" "custom_cron" "t" "tp" "dt" "dn" "dd" "tl" "tll" "tlr" "ipv6_enabled" "ip_source" "custom_ip_file" "custom_allip" "advanced" "proxy_mode" "github_proxy" "github_proxy_custom" "httping" "cfcolo" "node_test" "node_test_node" "node_test_url" "node_test_count" "node_test_timeout" "node_test_probes" "node_test_threads"
    get_servers_config "ssr_services" "ssr_enabled" "passwall_enabled" "passwall_services" "passwall2_enabled" "passwall2_services" "bypass_enabled" "bypass_services" "vssr_enabled" "vssr_services" "DNS_enabled" "AliDNS_ip_count" "HOST_enabled" "MosDNS_enabled" "MosDNS_ip_count" "openclash_restart" "AstraDNS_enabled" "AstraDNS_config" "AstraDNS_bin"
}

function appinit(){
    ssr_started='';
    passwall_started='';
    passwall2_started='';
    bypass_started='';
    vssr_started='';
    homeproxy_started='';
}

function homeproxy_client_active() {
    local routing_mode outbound_node

    routing_mode="$(uci get homeproxy.config.routing_mode 2>/dev/null)"
    if [ "x${routing_mode}" = "xcustom" ] ;then
        outbound_node="$(uci get homeproxy.routing.default_outbound 2>/dev/null)"
    else
        outbound_node="$(uci get homeproxy.config.main_node 2>/dev/null)"
    fi

    [ "x${outbound_node}" != "x" ] && [ "x${outbound_node}" != "xnil" ]
}

function prepare_homeproxy() {
    [ -f /etc/config/homeproxy ] || return 0
    homeproxy_client_active || return 0

    homeproxy_original_routing_mode="$(uci get homeproxy.config.routing_mode 2>/dev/null)"
    homeproxy_original_main_node="$(uci get homeproxy.config.main_node 2>/dev/null)"
    homeproxy_original_main_udp_node="$(uci get homeproxy.config.main_udp_node 2>/dev/null)"
    homeproxy_original_default_outbound="$(uci get homeproxy.routing.default_outbound 2>/dev/null)"

    if [ $proxy_mode == "close" ] ;then
        if [ "x${homeproxy_original_routing_mode}" = "xcustom" ] ;then
            uci set homeproxy.routing.default_outbound="nil"
        else
            uci set homeproxy.config.main_node="nil"
            uci set homeproxy.config.main_udp_node="nil"
        fi
    elif [ $proxy_mode == "gfw" ] ;then
        if [ "x${homeproxy_original_routing_mode}" = "xcustom" ] ;then
            echolog "HomeProxy 当前为自定义路由，测速期间临时停用客户端代理"
            uci set homeproxy.routing.default_outbound="nil"
        else
            uci set homeproxy.config.routing_mode="gfwlist"
        fi
    else
        return 0
    fi

    homeproxy_started='1'
    uci commit homeproxy
    /etc/init.d/homeproxy restart 2>/dev/null
}

function restore_homeproxy() {
    if [ "x${homeproxy_started}" != "x1" ] ;then
        return 0
    fi

    [ -n "$homeproxy_original_routing_mode" ] && uci set homeproxy.config.routing_mode="${homeproxy_original_routing_mode}"
    [ -n "$homeproxy_original_main_node" ] && uci set homeproxy.config.main_node="${homeproxy_original_main_node}"
    [ -n "$homeproxy_original_main_udp_node" ] && uci set homeproxy.config.main_udp_node="${homeproxy_original_main_udp_node}"
    [ -n "$homeproxy_original_default_outbound" ] && uci set homeproxy.routing.default_outbound="${homeproxy_original_default_outbound}"

    uci commit homeproxy
    /etc/init.d/homeproxy restart 2>/dev/null
    echolog "HomeProxy 重启完成"
}

check_wgetcurl(){
    echo "Checking for wget or curl..."
    which wget && downloader="wget --no-check-certificate -T 20 -O" && return
    which curl && downloader="curl -L -k --retry 2 --connect-timeout 20 -o" && return
    [ -z "$1" ] && opkg update || (echo "Failed to run opkg update" && exit 1)
    [ -z "$1" ] && (opkg remove wget wget-nossl --force-depends ; opkg install wget ; check_wgetcurl 1 ;return)
    [ "$1" == "1" ] && (opkg install curl ; check_wgetcurl 2 ; return)
    echo "Error: curl and wget not found" && exit 1
}

function get_github_mirror_prefix() {
    case "$github_proxy" in
        ghfast)
            echo "https://ghfast.top/"
            ;;
        ghproxy)
            echo "https://ghproxy.cc/"
            ;;
        custom)
            if [ -n "$github_proxy_custom" ] ;then
                case "$github_proxy_custom" in
                    */) echo "$github_proxy_custom" ;;
                    *) echo "${github_proxy_custom}/" ;;
                esac
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

function download_core() {
    um="$(uname -m)"
    OPENWRT_ARCH="$(awk -F'=' '/^OPENWRT_ARCH=/{gsub(/"/,"",$2); split($2,a,"_"); print a[1]}' /etc/os-release)"
    case "$um" in
        i386|i686)     Arch="386" ;;
        x86_64)        Arch="amd64" ;;
        aarch64)       Arch="arm64" ;;
        armv5*)        Arch="armv5" ;;
        armv6*)        Arch="armv6" ;;
        armv7*|armv8l) Arch="armv7" ;;
        mips*)
            case "$OPENWRT_ARCH" in
                mips64el) Arch="mips64le" ;;   # 64‑bit little‑endian
                mips64)   Arch="mips64"   ;;   # 64‑bit big‑endian
                mipsel)   Arch="mipsle"   ;;   # 32‑bit little‑endian
                mips)     Arch="mips"     ;;   # 32‑bit big‑endian
                *) echo "Error: unknown OpenWrt MIPS flavour '$OPENWRT_ARCH'"; exit 1 ;;
            esac
            ;;
        *) echo "Error: $um is not supported"; exit 1 ;;
    esac

    echo "Start download..."
    raw_link="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.4/cfst_linux_$Arch.tar.gz"
    github_mirror_prefix="$(get_github_mirror_prefix)"
    if [ -n "$github_mirror_prefix" ] ;then
        link="${github_mirror_prefix}${raw_link}"
    else
        link="${raw_link}"
    fi

    echolog "Core download URL: $link"
    check_wgetcurl

    $downloader /tmp/${link##*/} "$link" 2>&1
    if [ "$?" != "0" ]; then
        echo "Download failed"
        exit 1
    fi

    # Decompress .tar.gz to .tar, run ucode patch on the .tar, then extract the .tar
    gzfile="/tmp/${link##*/}"
    tarfile="${gzfile%.gz}"

    # If we have a .gz file, decompress it to produce a .tar
    if [ "${gzfile##*.}" = "gz" ] && [ -f "$gzfile" ]; then
        gzip -d "$gzfile" || (echo "Failed to decompress $gzfile" && exit 1)
    fi

    # If original was gz (now we have a .tar), run patch.uc on the tar then extract it
    if [ "${gzfile##*.}" = "gz" ]; then
        ucode /usr/bin/cloudflarespeedtest/patch.uc "$tarfile"
        tar -xf "$tarfile" -C "/tmp/"
        if [ ! -e "/tmp/cfst" ]; then
            echo "Failed to extract core from archive."
            exit 1
        fi
        downloadbin="/tmp/cfst"
    fi

    echo "Download success. Start copy."
    mv -f "$downloadbin" /usr/bin/cdnspeedtest
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

# 按「下载速度(第6列)降序、平均延迟(第5列)升序」排序结果数据行，表头保留在首行。
# 兼容测速被中断、二进制未完成最终排序的情况，保证最快 IP 位于首行。
function sort_result(){
    local file="$1"
    [ -s "$file" ] || return 0
    local header
    header=$(sed -n '1p' "$file" 2>/dev/null)
    {
        [ -n "$header" ] && echo "$header"
        sed '1d' "$file" 2>/dev/null | grep -v '^#' | LC_ALL=C sort -t, -k6,6rn -k5,5n 2>/dev/null
    } > "${file}.sorted" 2>/dev/null
    [ -s "${file}.sorted" ] && mv -f "${file}.sorted" "$file" || rm -f "${file}.sorted"
}

function select_ip_file(){
    case "${ip_source:-}" in
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
            if [ "${ipv6_enabled:-0}" = "1" ]; then
                echo "$IPV6_TXT"
            else
                echo "$IPV4_TXT"
            fi
            ;;
        *)
            echolog "Unknown IP list source: ${ip_source}, fallback to built-in IPv4 list" >/dev/null
            echo "$IPV4_TXT"
            ;;
    esac
}

function speed_test(){

    # 走节点测速模式：用待测 IP 替换 passwall 节点 address，经该节点本地 SOCKS 探测延迟。
    # 取代 cdnspeedtest 直连路径，跳过 proxy_mode 改写（走节点时不需要切代理模式）。
    if [ "${node_test:-0}" = "1" ]; then
        node_speed_test
        return $?
    fi

    rm -rf $LOG_FILE
    mkdir -p "$RESULT_DIR"
    result_tmp="$(mktemp "${RESULT_DIR}/result.csv.tmp.XXXXXX")" || {
        echolog "创建临时测速结果文件失败"
        return 1
    }

    if [ ! -e /usr/bin/cdnspeedtest ]; then
        download_core >>$LOG_FILE
    fi

    command="/usr/bin/cdnspeedtest -sl ${speed_limit} -url ${custom_url} -o ${result_tmp}"

    selected_ip_file="$(select_ip_file)"
    command="${command} -f ${selected_ip_file}"

    if [ "${ip_source:-}" = "custom_file" ] && [ "${custom_allip:-0}" = "1" ] ; then
        command="${command} -allip"
    fi

    if [ $advanced -eq "1" ] ; then
        command="${command} -tl ${tl} -tll ${tll} -tlr ${tlr:-0.2} -n ${threads} -t ${t} -dt ${dt} -dn ${dn}"
        if [ $dd -eq "1" ] ; then
            command="${command} -dd"
        fi
        if [ $tp -ne "443" ] ; then
            command="${command} -tp ${tp}"
        fi
        if [ "${httping:-0}" -eq "1" ] ; then
            command="${command} -httping"
            if [ -n "${cfcolo:-}" ] ; then
                command="${command} -cfcolo ${cfcolo}"
            fi
        fi
    else
        # Default param: -tl 200 -tll 40 -tlr 0.2 -n 200 -t 4 -dt 10
        command="${command} -tl ${tl} -tll ${tll} -tlr ${tlr:-0.2} -dn 5"
    fi

    appinit

    ssr_original_server=$(uci get shadowsocksr.@global[0].global_server 2>/dev/null)
    ssr_original_run_mode=$(uci get shadowsocksr.@global[0].run_mode 2>/dev/null)
    if [ "x${ssr_original_server}" != "xnil" ] && [ "x${ssr_original_server}"  !=  "x" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set shadowsocksr.@global[0].global_server="nil"
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set shadowsocksr.@global[0].run_mode="gfw"
        fi
        ssr_started='1';
        uci commit shadowsocksr
        /etc/init.d/shadowsocksr restart
    fi

    passwall_server_enabled=$(uci get passwall.@global[0].enabled 2>/dev/null)
    passwall_original_run_mode=$(uci get passwall.@global[0].tcp_proxy_mode 2>/dev/null)
    if [ "x${passwall_server_enabled}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall.@global[0].enabled="0"
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set passwall.@global[0].tcp_proxy_mode="gfwlist"
        fi
        passwall_started='1';
        uci commit passwall
        /etc/init.d/passwall  restart 2>/dev/null
    fi

    passwall2_server_enabled=$(uci get passwall2.@global[0].enabled 2>/dev/null)
    passwall2_original_run_mode=$(uci get passwall2.@global[0].tcp_proxy_mode 2>/dev/null)
    if [ "x${passwall2_server_enabled}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall2.@global[0].enabled="0"
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set passwall2.@global[0].tcp_proxy_mode="gfwlist"
        fi
        passwall2_started='1';
        uci commit passwall2
        /etc/init.d/passwall2 restart 2>/dev/null
    fi

    vssr_original_server=$(uci get vssr.@global[0].global_server 2>/dev/null)
    vssr_original_run_mode=$(uci get vssr.@global[0].run_mode 2>/dev/null)
    if [ "x${vssr_original_server}" != "xnil" ] && [ "x${vssr_original_server}"  !=  "x" ] ;then

        if [ $proxy_mode  == "close" ] ;then
            uci set vssr.@global[0].global_server="nil"
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set vssr.@global[0].run_mode="gfw"
        fi
        vssr_started='1';
        uci commit vssr
        /etc/init.d/vssr restart
    fi

    bypass_original_server=$(uci get bypass.@global[0].global_server 2>/dev/null)
    bypass_original_run_mode=$(uci get bypass.@global[0].run_mode 2>/dev/null)
    if [ "x${bypass_original_server}" != "x" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set bypass.@global[0].global_server=""
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set bypass.@global[0].run_mode="gfw"
        fi
        bypass_started='1';
        uci commit bypass
        /etc/init.d/bypass restart
    fi

    if [ "x${MosDNS_enabled}" == "x1" ] ;then
        if [ -n "$(grep 'option cloudflare' /etc/config/mosdns)" ]
        then
            sed -i".bak" "/option cloudflare/d" /etc/config/mosdns
        fi
        sed -i '/^$/d' /etc/config/mosdns && echo -e "\toption cloudflare '0'" >> /etc/config/mosdns

        /etc/init.d/mosdns restart &>/dev/null
        if [ "x${openclash_restart}" == "x1" ] ;then
            /etc/init.d/openclash restart &>/dev/null
        fi
    fi

    prepare_homeproxy

    echo $command >> $LOG_FILE 2>&1
    echolog "-----------start----------"
    rc_file='/tmp/cf_speedtest_rc'
    rm -f "$rc_file"
    ( $command 2>&1; echo $? > "$rc_file" ) | tr '\r' '\n' | awk -f /usr/bin/cloudflarespeedtest/progress.awk >> $LOG_FILE
    command_rc="$(cat "$rc_file" 2>/dev/null)"
    [ -n "$command_rc" ] || command_rc=0
    rm -f "$rc_file"
    echolog "-----------end------------"

    if [ $command_rc -ne 0 ]; then
        echolog "CloudflareST 测速被中断或异常退出（返回码 $command_rc），尝试保存已获取的结果"
    fi

    if [ -z "$(first_result_ip "$result_tmp")" ]; then
        echolog "CloudflareST 测速结果 IP 数量为 0，保留上一次结果"
        rm -f "$result_tmp"
        return 1
    fi

    # 对结果按下载速度降序排序（兼容被中断时未完成排序的情况），保证最快 IP 位于首行。
    sort_result "$result_tmp"

    # Append current time to the validated result, then rotate old results.
    echo "# Speed test time: $(date +'%Y-%m-%d %H:%M:%S')" >> "$result_tmp"
    rotate_result_files
    mv -f "$result_tmp" "$IP_FILE"
}

# ── 走节点测速模式 ──────────────────────────────────────────────
# 把每个候选 CF IP 临时写进一个 passwall 节点的 address，再用 passwall 式
# URL 测速（拉起该节点本地 SOCKS → curl -I 探测 → 取 time_pretransfer 得毫秒）
# 按延迟选最优 IP，测完把最优 IP 留在该节点 address。只测延迟，不测下载带宽。
NODE_TEST_FLAG=""
NODE_TEST_NODE=""
NODE_TEST_ORIG_ADDR=""
NODE_TEST_DONE=0
NODE_TEST_TMP_NODES=""

node_test_cleanup() {
    [ "${NODE_TEST_CLEANED:-0}" = "1" ] && return
    NODE_TEST_CLEANED=1
    # 杀本次拉起的临时 SOCKS 进程（按 flag 匹配，排除脚本自身）
    if [ -n "${NODE_TEST_FLAG}" ]; then
        local pid_file
        for pid_file in /tmp/etc/passwall/*"${NODE_TEST_FLAG}"*_plugin.pid; do
            [ -s "$pid_file" ] && kill -9 "$(head -n1 "$pid_file")" >/dev/null 2>&1
        done
        busybox pgrep -af "${NODE_TEST_FLAG}" 2>/dev/null | awk '! /cloudflarespeedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
        rm -rf /tmp/etc/passwall/*"${NODE_TEST_FLAG}"* 2>/dev/null
    fi
    # 删除本次创建的临时克隆节点（Phase2 并行模式）
    if [ -n "${NODE_TEST_TMP_NODES:-}" ]; then
        local t
        for t in $NODE_TEST_TMP_NODES; do
            uci -q delete "passwall.$t"
        done
        uci -q commit passwall
    fi
}

# 克隆源 passwall 节点到临时 section（复制所有标量选项；list 选项用 add_list）
clone_passwall_node() {
    local src=$1 dst=$2
    uci -q set "passwall.${dst}=nodes"
    local prefix="passwall.${src}."
    local tmp opts_file line rest opt val cnt
    tmp=$(mktemp)
    opts_file=$(mktemp)
    uci -q show "passwall.${src}" 2>/dev/null > "$tmp"
    # 第一遍：抽取每个 option 名到 opts_file（用于 list 检测）
    while IFS= read -r line; do
        case "$line" in
            "$prefix"*)
                rest="${line#$prefix}"
                opt="${rest%%=*}"
                [ "$opt" = "$rest" ] && continue
                printf '%s\n' "$opt" >> "$opts_file"
                ;;
        esac
    done < "$tmp"
    # 第二遍：回放（同名 option 出现 >1 次即 list，用 add_list；否则 set）
    while IFS= read -r line; do
        case "$line" in
            "$prefix"*)
                rest="${line#$prefix}"
                opt="${rest%%=*}"
                [ "$opt" = "$rest" ] && continue
                val="${rest#*=}"
                cnt=$(grep -cx -- "$opt" "$opts_file" 2>/dev/null)
                if [ "${cnt:-1}" -le 1 ]; then
                    uci -q set "passwall.${dst}.${opt}=${val}"
                else
                    uci -q add_list "passwall.${dst}.${opt}=${val}"
                fi
                ;;
        esac
    done < "$tmp"
    rm -f "$tmp" "$opts_file"
}

node_speed_test() {
    # 校验 passwall 已安装
    [ -f /usr/share/passwall/app.sh ] || { echolog "未安装 passwall，无法使用走节点测速模式"; return 1; }
    [ -f /usr/share/passwall/utils.sh ] || { echolog "缺少 passwall utils.sh，无法使用走节点测速模式"; return 1; }
    # passwall 的 utils.sh 会覆盖 LOG_FILE 与 echolog()，先保存再恢复，避免日志写进 passwall 的日志文件
    local _cfst_log_file="$LOG_FILE"
    . /usr/share/passwall/utils.sh
    LOG_FILE="$_cfst_log_file"
    echolog() {
        local d="$(date "+%Y-%m-%d %H:%M:%S")"
        echo -e "$d: $*"
        echo -e "$d: $*" >>$LOG_FILE
    }

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

    NODE_TEST_FLAG="node_test_$$"
    NODE_TEST_DONE=0
    NODE_TEST_CLEANED=0
    NODE_TEST_TMP_NODES=""
    trap node_test_cleanup EXIT INT TERM

    rm -rf $LOG_FILE
    mkdir -p "$RESULT_DIR"
    result_tmp="$(mktemp "${RESULT_DIR}/result.csv.tmp.XXXXXX")" || { echolog "创建临时测速结果文件失败"; return 1; }

    # CSV 表头（与 cdnspeedtest 一致，7 列）
    echo "IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码" > "$result_tmp"

    selected_ip_file="$(select_ip_file)"
    [ -f "$selected_ip_file" ] || { echolog "候选 IP 列表文件不存在: $selected_ip_file"; return 1; }

    # 读取候选 IP，截断到 node_test_count
    local count="${node_test_count:-30}"
    case "$count" in ''|*[!0-9]*) count=30 ;; esac
    [ "$count" -gt 0 ] || count=30

    local ip_list total
    ip_list=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$selected_ip_file" | head -n "$count")
    total=$(echo "$ip_list" | grep -c .)
    [ "$total" -gt 0 ] || { echolog "候选 IP 列表为空"; return 1; }

    local probe_url="${node_test_url:-https://www.google.com/generate_204}"
    local timeout="${node_test_timeout:-5}"
    case "$timeout" in ''|*[!0-9]*) timeout=5 ;; esac
    # 节点模式探测次数独立于 cdnspeedtest 的 t：默认 1（与 passwall 单次探测一致），上限 5
    local probes="${node_test_probes:-1}"
    case "$probes" in ''|*[!0-9]*) probes=1 ;; esac
    [ "$probes" -ge 1 ] 2>/dev/null || probes=1
    [ "$probes" -le 5 ] 2>/dev/null || probes=5

    # 并行度 K（默认 5，上限 16，不超过候选数）
    local K="${node_test_threads:-5}"
    case "$K" in ''|*[!0-9]*) K=5 ;; esac
    [ "$K" -ge 1 ] 2>/dev/null || K=5
    [ "$K" -le 16 ] 2>/dev/null || K=16
    [ "$K" -gt "$total" ] && K=$total

    # 预创建 K 个临时克隆节点（复制源节点协议配置，只换 address；源节点全程不动）
    local i tmp
    for i in $(seq 1 $K); do
        tmp="cfst_nt_${NODE_TEST_FLAG}_${i}"
        clone_passwall_node "$NODE_TEST_NODE" "$tmp"
        uci -q set "passwall.${tmp}.remarks=[cfst-temp-${i}]"
        NODE_TEST_TMP_NODES="$NODE_TEST_TMP_NODES $tmp"
    done
    uci -q commit passwall

    echolog "开始走节点测速（节点: ${NODE_TEST_NODE}, 候选: ${total} 个, 每IP探测 ${probes} 次, 并行 ${K}, 超时 ${timeout}s）"
    echolog "提示：测速经 ${K} 个临时克隆节点进行，源节点不受影响，测完把最优 IP 写回源节点"

    # 候选 IP 落盘以便按批切片
    local ip_tmp
    ip_tmp=$(mktemp)
    printf '%s\n' "$ip_list" > "$ip_tmp"

    local nbatches=$(( (total + K - 1) / K ))
    local b
    for b in $(seq 1 $nbatches); do
        local start=$(( (b - 1) * K + 1 ))
        local end=$(( start + K - 1 ))
        [ "$end" -gt "$total" ] && end=$total
        local batch_ips
        batch_ips=$(sed -n "${start},${end}p" "$ip_tmp")
        local batch_n
        batch_n=$(printf '%s\n' "$batch_ips" | grep -c .)

        # 主进程串行：把本批 IP 写入各临时克隆节点 address，一次性 commit（不并发写 uci）
        local w=0
        for tmp in $NODE_TEST_TMP_NODES; do
            w=$((w + 1))
            [ "$w" -gt "$batch_n" ] && break
            local ip_b
            ip_b=$(printf '%s\n' "$batch_ips" | sed -n "${w}p")
            uci -q set "passwall.${tmp}.address=${ip_b}"
        done
        uci -q commit passwall

        # 每批分配 K 个端口（auto 模式跨进程协调、互不冲突，且每批用新端口避免 TIME_WAIT 复用）
        local ports_file
        ports_file=$(mktemp)
        w=0
        for tmp in $NODE_TEST_TMP_NODES; do
            w=$((w + 1))
            [ "$w" -gt "$batch_n" ] && break
            get_new_port auto tcp,udp >> "$ports_file"
        done

        # 并行：起 K 个 worker，各拉本地 SOCKS + 就绪轮询探测 + 清理，结果写各自文件
        w=0
        for tmp in $NODE_TEST_TMP_NODES; do
            w=$((w + 1))
            [ "$w" -gt "$batch_n" ] && break
            local ip_b port
            ip_b=$(printf '%s\n' "$batch_ips" | sed -n "${w}p")
            port=$(sed -n "${w}p" "$ports_file")
            local wflag="${NODE_TEST_FLAG}_w${w}"
            (
                NO_REC_PROCESS=1 /usr/share/passwall/app.sh run_socks \
                    flag="${wflag}" node=${tmp} \
                    bind=127.0.0.1 socks_port=${port} \
                    config_file=${wflag}.json >>"$LOG_FILE" 2>&1

                # 就绪轮询 + 就绪即探测（合并）——子shell内不用 local（ash 不允许在子shell里用 local）
                sent=0 recv=0 latencies="" probes_done=0 not_ready=0
                while [ $probes_done -lt $probes ]; do
                    res=$(curl -x socks5h://127.0.0.1:${port} -I -skL \
                        --connect-timeout 3 --max-time ${timeout} \
                        -o /dev/null -w "%{http_code}:%{time_pretransfer}" "${probe_url}" 2>/dev/null)
                    rc=$?
                    if [ $rc -eq 7 ]; then
                        not_ready=$((not_ready + 1))
                        [ $not_ready -ge 10 ] && break
                        sleep 0.3
                        continue
                    fi
                    not_ready=0
                    sent=$((sent + 1))
                    probes_done=$((probes_done + 1))
                    code="${res%%:*}"
                    tpre="${res##*:}"
                    case "$code" in
                        200|204|301|302|307|308|40[0-9])
                            recv=$((recv + 1))
                            latencies="${latencies} ${tpre}"
                            ;;
                    esac
                done

                # 清理本 worker 的 SOCKS
                for pid_file in /tmp/etc/passwall/*"${wflag}"*_plugin.pid; do
                    [ -s "$pid_file" ] && kill -9 "$(head -n1 "$pid_file")" >/dev/null 2>&1
                done
                busybox pgrep -af "${wflag}" 2>/dev/null | awk '! /cloudflarespeedtest\.sh/{print $1}' | xargs kill -9 >/dev/null 2>&1
                rm -rf /tmp/etc/passwall/*"${wflag}"* 2>/dev/null

                # 计算平均延迟与丢包率
                avg_ms=0 loss="1.00"
                if [ $recv -gt 0 ]; then
                    loss=$(awk -v s=$sent -v r=$recv 'BEGIN{printf "%.2f", (s-r)/s}')
                    avg_ms=$(echo "$latencies" | tr ' ' '\n' | grep -E '^[0-9.]+$' | awk '{s+=$1; n++} END{ if(n>0) printf "%.2f", s/n*1000 }')
                    [ -z "$avg_ms" ] && avg_ms=0
                fi

                # 过滤
                keep=1
                if [ $recv -eq 0 ]; then
                    keep=0
                else
                    if [ -n "${tl:-}" ] && [ "${tl}" -gt 0 ] 2>/dev/null; then
                        [ "$(awk -v v=$avg_ms -v c=$tl 'BEGIN{print (v>c)?1:0}')" = "1" ] && keep=0
                    fi
                    if [ -n "${tll:-}" ] && [ "${tll}" -gt 0 ] 2>/dev/null; then
                        [ "$(awk -v v=$avg_ms -v c=$tll 'BEGIN{print (v<c)?1:0}')" = "1" ] && keep=0
                    fi
                    if [ -n "${tlr:-}" ]; then
                        [ "$(awk -v v=$loss -v c=$tlr 'BEGIN{print (v>c)?1:0}')" = "1" ] && keep=0
                    fi
                fi

                # 单 IP 日志：直接追加 LOG_FILE（worker 的 stdout 已重定向到结果文件，不能用 echolog）
                status=$([ $keep -eq 1 ] && echo "保留" || echo "丢弃")
                echo "$(date '+%Y-%m-%d %H:%M:%S'): 进度: 走节点测速 $(( (b - 1) * K + w ))/${total} - ${ip_b} 延迟 ${avg_ms}ms 丢包 ${loss} [${status}]" >> "$LOG_FILE"

                if [ $keep -eq 1 ]; then
                    echo "${ip_b},${sent},${recv},${loss},${avg_ms},0.00,"
                fi
            ) > "${ip_tmp}.b${b}.w${w}" 2>/dev/null &
        done
        wait

        # 收集本批 worker 结果
        local wf
        for wf in "${ip_tmp}.b${b}".w*; do
            [ -s "$wf" ] && cat "$wf" >> "$result_tmp"
            rm -f "$wf"
        done
        rm -f "$ports_file"
    done

    rm -f "$ip_tmp"

    # 删除临时克隆节点
    for tmp in $NODE_TEST_TMP_NODES; do
        uci -q delete "passwall.$tmp"
    done
    uci -q commit passwall
    NODE_TEST_TMP_NODES=""

    # 排序（下载列全 0.00 → 按延迟升序）
    sort_result "$result_tmp"

    if [ -z "$(first_result_ip "$result_tmp")" ]; then
        echolog "走节点测速结果 IP 数量为 0，保留上一次结果（源节点未改动）"
        rm -f "$result_tmp"
        NODE_TEST_DONE=1
        node_test_cleanup
        trap - EXIT INT TERM
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

    NODE_TEST_DONE=1
    node_test_cleanup
    trap - EXIT INT TERM
    return 0
}

function ip_replace(){

    # 获取最快 IP（从 result.csv 结果文件中获取第一个 IP）
    bestip=$(first_result_ip "$IP_FILE")
    if [[ -z "${bestip}" ]]; then
        echolog "CloudflareST 测速结果 IP 数量为 0,跳过下面步骤..."
    else
        host_ip
        mosdns_ip
        astra_dns_ip
        alidns_ip
        # 走节点测速模式下,bestip 只对 node_test_node 最优,不写其它代理节点(它们是别的节点,该 IP 没替它们测过)
        if [ "${node_test:-0}" != "1" ]; then
            ssr_best_ip
            vssr_best_ip
            bypass_best_ip
            passwall_best_ip
            passwall2_best_ip
        fi

    fi

    restart_app
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

        if [ ! -x /usr/bin/cloudflarespeedtest/astra-dns.sh ]; then
            echolog "astra-dns 写入失败: /usr/bin/cloudflarespeedtest/astra-dns.sh 不存在"
            return 1
        fi

        if /usr/bin/cloudflarespeedtest/astra-dns.sh --result-csv "$IP_FILE" --config "$astra_config" --bin "$astra_bin" >>$LOG_FILE 2>&1; then
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

function restart_app(){
    if [ "x${ssr_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set shadowsocksr.@global[0].global_server="${ssr_original_server}"
            elif [ $proxy_mode  == "gfw" ] ;then
            uci set  shadowsocksr.@global[0].run_mode="${ssr_original_run_mode}"
        fi
        uci commit shadowsocksr
        /etc/init.d/shadowsocksr restart &>/dev/null
        echolog "ssr重启完成"
    fi

    if [ "x${passwall_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall.@global[0].enabled="${passwall_server_enabled}"
            elif [ $proxy_mode  == "gfw" ] ;then
            uci set passwall.@global[0].tcp_proxy_mode="${passwall_original_run_mode}"
        fi
        uci commit passwall
        /etc/init.d/passwall restart 2>/dev/null
        echolog "passwall重启完成"
    fi

    if [ "x${passwall2_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall2.@global[0].enabled="${passwall2_server_enabled}"
            elif [ $proxy_mode  == "gfw" ] ;then
            uci set passwall2.@global[0].tcp_proxy_mode="${passwall2_original_run_mode}"
        fi
        uci commit passwall2
        /etc/init.d/passwall2 restart 2>/dev/null
        echolog "passwall2重启完成"
    fi

    if [ "x${vssr_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set vssr.@global[0].global_server="${vssr_original_server}"
            elif [ $proxy_mode  == "gfw" ] ;then
            uci set vssr.@global[0].run_mode="${vssr_original_run_mode}"
        fi
        uci commit vssr
        /etc/init.d/vssr restart &>/dev/null
        echolog "Vssr重启完成"
    fi

    if [ "x${bypass_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set bypass.@global[0].global_server="${bypass_original_server}"
            elif [ $proxy_mode  == "gfw" ] ;then
            uci set  bypass.@global[0].run_mode="${bypass_original_run_mode}"
        fi
        uci commit bypass
        /etc/init.d/bypass restart &>/dev/null
        echolog "Bypass重启完成"
    fi

    restore_homeproxy
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
                if /usr/bin/cloudflarespeedtest/aliddns.sh "$app_key" "$app_secret" "$main_domain" "$sub" "$line" "$bestip_is_ipv6" $bestips; then
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
