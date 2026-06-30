# luci-app-cloudflarespeedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/stevenjoezhang/luci-app-cloudflarespeedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/stevenjoezhang/luci-app-cloudflarespeedtest?style=for-the-badge)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases)

[English](README.md)

**luci-app-cloudflarespeedtest** 是一个用于 OpenWrt 的 LuCI 插件，基于 [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) 核心工具开发。它可以自动测试 Cloudflare IP 的延迟和下载速度，筛选出最适合当前网络环境的优选 IP，并自动更新到 SSR+、Passwall 等代理插件中，从而实现对 Cloudflare 托管网站的访问加速。

本项目 fork 自 [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)，并在原版基础上进行了大量的重构与改进。

## 主要特性

*   **自动测速与优选**：定期或手动运行 CloudflareSpeedTest，筛选最佳 IP。
*   **应用到代理插件**：支持自动将优选 IP 应用到 SSR+、Passwall 等常见 OpenWrt 代理工具。
*   **可视化图表**：新增历史数据图表，直观展示延迟与下载速度的波动趋势。
*   **自动下载核心**：插件包不包含核心二进制文件，首次运行时会自动下载，减小安装包体积，降低部署门槛。
*   **优化的界面与日志**：重新设计的状态展示与日志格式，进度与报错更清晰。
*   **日志中的总进度**：测速日志会按约 1% 步进输出总进度，例如 `进度: 延迟测速 4051/8192 (49%)`，直观展示已测 IP 数量与总数，避免逐条进度刷屏。
*   **GitHub 镜像加速**：首次下载核心时可选 direct / ghfast / ghproxy / 自定义镜像，提升国内下载成功率。
*   **中途停止不丢结果**：测速被中途停止时，自动排序并保存已测得的部分结果，不丢失进度。
*   **丢包率过滤**：支持 `-tlr` 丢包率上限过滤，默认模式与高级模式均生效。
*   **ucode 重构后端**：后端已从 Lua 迁移到 ucode，自带阿里云 DNS HMAC-SHA1 签名，无需额外 Lua 依赖。
*   **丰富的应用集成**：优选 IP 可自动应用到 SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / 阿里云 DDNS。

## 功能详情

### 界面页面

插件在 LuCI → 服务 → CloudflareSpeedTest 下提供三个页面：

*   **主设置页（Plugin Settings）**：包含「基本 / 计划 / 高级」三个 Tab，提供 Start/Stop 测速按钮、3 秒轮询的状态条、Best IP 只读区，以及延迟与下载速度的历史折线图。
*   **第三方集成页（Third Party Settings）**：按本机已安装的代理软件按需显示对应 Tab，用于选择要把优选 IP 写入哪些节点、域名或 DNS 服务。
*   **日志页（Logs）**：增量拉取测速日志，可勾选每 5 秒自动刷新；运行中会内联展示总进度（已测 IP 数 / 总数）。

### 测速参数与模式

*   **默认模式**：使用 `-tl 200 -tll 40 -tlr 0.2 -dn 5`，分别对应延迟上限、延迟下限、丢包率上限与下载测速节点数。
*   **高级模式（Advanced 开关）**：进一步开放线程数 `-n`、延迟测速时间 `-t`、下载测速时间 `-dt`、端口 `-tp`、`-dd` 禁用下载测速、`-httping` + `-cfcolo` HTTP 延迟测速等参数。
*   **IP 来源**：可使用内置 IPv4 / IPv6 列表或自定义 IP 文件，并可选 `-allip` 扫描每个 /24 网段。

### 优选 IP 的应用方式

测速完成后，最优 IP 会**自动写入**下列集成，无需手动点击「应用」：

*   **HOST**：写入 `/etc/hosts` 并 reload dnsmasq。
*   **MosDNS**：写入 `/etc/config/mosdns` 的 `cloudflare_ip`，可选附带重启 OpenClash。
*   **astra-dns**：改写其 YAML 配置并通过 SIGHUP 热重载。
*   **阿里云 DDNS**：自动选择 A / AAAA 记录，支持写入多个 IP。
*   **代理节点**：写入 ssr / passwall / passwall2 / bypass / vssr 的 `server` / `address` 字段。

> 注：插件不修改 `ip route` 或网卡路由，优选 IP 仅通过 hosts / DNS / 代理节点三条路径生效。

### 定时任务

内置 cron 调度，支持按 1~24 小时间隔运行，或填写自定义 cron 表达式。`init.d` 脚本以幂等方式按需更新 crontab，不会重复写入。

### 代理模式（测速期间临时切换）

为避免测速流量被本机代理污染，测速期间会临时切换代理软件运行模式，测完自动还原：

*   **HOLD（`nil`）**：保持当前代理模式不变。
*   **GFW List（`gfw`，默认）**：测速 IP 走直连，命中 GFW 列表的流量仍走代理。
*   **CLOSE（`close`）**：测速期间临时停用代理，测完还原。

### 结果与历史

测速结果保存在 `/tmp/CloudflareSpeedTest/result.csv`，滚动保留 10 个历史版本；Best IP 区显示最近 100 行，历史图表取最近 10 次结果绘制延迟与下载速度趋势。

## 安装与使用

1.  从 [Releases](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases) 页面下载最新的 `.ipk` 或 `.apk` 文件。
2.  上传到路由器并安装：
    ```bash
    opkg install luci-app-cloudflarespeedtest_*.ipk
    ```
    *注：如果安装时提示缺少依赖，请先更新 opkg 源 (`opkg update`)。*
3.  进入 LuCI 界面 -> 服务 -> CloudflareSpeedTest 进行配置。

## 截图

![概览](screenshots/overview.png)
![历史趋势](screenshots/chart.png)

## 编译

```bash
# 仅编译软件包
make package/luci-app-cloudflarespeedtest/compile V=99

# 编译完整固件
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-cloudflarespeedtest..... for LuCI ----> save
make V=99
```

## 致谢

*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)
