# luci-app-passwall-speedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/stevenjoezhang/luci-app-cloudflarespeedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/stevenjoezhang/luci-app-cloudflarespeedtest?style=for-the-badge)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases)

[English](README.md)

**luci-app-passwall-speedtest** 是一个用于 OpenWrt 的 LuCI 插件：**通过你已有的 [PassWall](https://github.com/xiaorouji/openwrt-passwall) 节点**对候选 Cloudflare IP 测延迟来优选 IP。它把每个候选 IP 临时写进一个 passwall 节点的 `address`，用 passwall 拉起本地 SOCKS，再用 `curl -I` 取 `time_pretransfer` 测延迟；测完把最优 IP 写回 passwall 节点及其它集成。

> 这是对原 `luci-app-cloudflarespeedtest` 的重构：**已移除独立 CloudflareSpeedTest 二进制的下载与依赖**，测速完全经由 passwall 完成，不再下载或内置任何外部测速二进制。只测延迟，不测下载带宽。

## 依赖

*   **PassWall**（`openwrt-passwall`）必须已安装——测速会调用 `/usr/share/passwall/app.sh run_socks`。未安装 passwall 时测速会报错并中止。
*   **curl**（硬依赖），用于延迟探测。
*   至少一个 CF-CDN 前置的 passwall 节点（VLESS / VMess / Trojan / SS …）。SOCKS 类型的 passwall 节点不能用作测速节点（其 `address` 本身就是 SOCKS 服务器）。

## 主要特性

*   **走节点测速**：经你的 passwall 节点链路探测候选 Cloudflare IP——选出的是「从你代理出口看」最优的 CF IP。
*   **多线程 worker**：在「第三方设置」里选的 passwall 节点作为并行 worker——每个 worker 经自己的链路测全部候选 IP、各写各的最优 IP；并发上限由 `node_test_threads` 控制。
*   **多探测 fail-fast**：每个 IP 探测 `node_test_probes` 次；任意一次失败该 IP 立即丢弃。只有全部探测都成功的 IP 才保留，确保结果稳定。
*   **应用到代理插件**：最优 IP 自动写回 ssr / passwall / passwall2 / bypass / vssr 节点，以及 HOST / MosDNS / astra-dns / 阿里云 DDNS。
*   **可视化图表**：延迟历史趋势图（下载速度图已移除——走节点测速只测延迟）。
*   **优化的界面与日志**：重新设计的状态展示；逐 IP 日志如 `进度: 走节点测速 [节点] 5/30 (16%) - 1.2.3.4 延迟 87ms 丢包 0.00 [保留]`。
*   **中途停止不丢结果**：中途停止会触发 trap 清理 SOCKS、恢复节点 address，若无新结果则保留上一次结果。
*   **丰富的应用集成**：优选 IP 可自动应用到 SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / 阿里云 DDNS。

## 界面页面

插件在 LuCI → 服务 → PassWall Speed Test 下提供三个页面：

*   **主设置页（Plugin Settings）**：包含「基本 / 计划」两个 Tab，提供 Start/Stop 测速按钮、3 秒轮询的状态条、Best IP 只读区，以及延迟历史折线图。
*   **第三方集成页（Third Party Settings）**：按本机已安装的代理软件按需显示对应 Tab；此处选中的 passwall 节点同时作为多线程 worker。
*   **日志页（Logs）**：增量拉取测速日志，可勾选每 5 秒自动刷新。

## 测速参数

*   **IP 列表来源**：内置 IPv4 / IPv6 列表或自定义 IP 文件，可选「扫描每个 /24 中的全部 IP」。
*   **延迟上限 / 下限 / 丢包率上限**（`tl` / `tll` / `tlr`）：丢弃超出阈值的候选 IP（单位：ms / ms / 0–1）。
*   **用于测速的 passwall 节点**：未选 passwall worker 时的单节点回退。
*   **探测 URL**：经节点本地 SOCKS 探测的 URL（HTTP HEAD），默认 Google `generate_204`。
*   **最大测速 IP 数**：每个 worker 测试的候选 IP 数上限。
*   **探测超时**：每个 IP 的 curl `--max-time`（秒）。
*   **每 IP 探测次数**：每个 IP 的 curl 探测次数（全部成功才保留）。
*   **最大并发 worker**：多节点模式的并发上限（0 = 全部）。

## 优选 IP 的应用方式

测速完成后：

*   每个 passwall worker 节点会写回各自的最优 IP 到 `passwall.<节点>.address`。
*   全局最低延迟 IP 自动写入：HOST（`/etc/hosts`）、MosDNS、astra-dns、阿里云 DDNS，以及 ssr / passwall / passwall2 / bypass / vssr 节点的 `server`/`address` 字段。

> 注：插件不修改 `ip route`。优选 IP 仅通过 hosts / DNS / 代理节点生效。

## 定时任务

内置 cron 调度，支持按 1~24 小时间隔运行，或填写自定义 cron 表达式。`init.d` 脚本以幂等方式按需更新 crontab，不会重复写入。

## 结果与历史

测速结果保存在 `/tmp/passwall-speedtest/result.csv`，滚动保留 10 个历史版本；Best IP 区显示最近 100 行，延迟图表取最近 10 次结果绘制。

## 安装与使用

1.  从 [Releases](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases) 页面下载最新的 `.ipk` 或 `.apk` 文件。
2.  上传到路由器并安装：
    ```bash
    opkg install luci-app-passwall-speedtest_*.ipk
    ```
    *注：如果安装时提示缺少依赖，请先更新 opkg 源 (`opkg update`)。*
3.  进入 LuCI 界面 → 服务 → PassWall Speed Test 进行配置。
    > 从旧版 `luci-app-cloudflarespeedtest` 升级：UCI 配置已改名为 `passwall-speedtest`，旧设置**不会**自动迁移，请在 LuCI 页面重新配置；旧 `/etc/config/cloudflarespeedtest` 可自行删除。

## 截图

![概览](screenshots/overview.png)
![历史趋势](screenshots/chart.png)

## 编译

```bash
# 仅编译软件包
make package/luci-app-passwall-speedtest/compile V=99

# 编译完整固件
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-passwall-speedtest..... for LuCI ----> save
make V=99
```

## 致谢

*   [openwrt-passwall](https://github.com/xiaorouji/openwrt-passwall)
*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（沿用其 IP 列表格式）
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)