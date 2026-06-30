# luci-app-cloudflarespeedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/stevenjoezhang/luci-app-cloudflarespeedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/stevenjoezhang/luci-app-cloudflarespeedtest?style=for-the-badge)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases)

[中文说明](README.CN.md)

**luci-app-cloudflarespeedtest** is a LuCI application for OpenWrt, based on the [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) core tool. It automatically tests the latency and download speed of Cloudflare IPs, selects the best ones for your network, and updates them to proxy plugins like SSR+ and Passwall.

This project is a fork of [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest) with significant refactoring and improvements.

## Features

*   **Auto Speed Test**: Periodically or manually test Cloudflare IPs to find the best one.
*   **Proxy Integration**: Automatically update the best IP to SSR+, Passwall, MosDNS, astra-dns, and other proxy or DNS tools.
*   **Visual Charts**: View history charts for latency and download speed trends.
*   **Auto Core Download**: The package does not contain the core binary; it downloads automatically on the first run, reducing the package size.
*   **Improved UI & Logs**: Redesigned status display and log format for better readability.
*   **Overall Progress in Log**: The speed-test log prints throttled overall progress (e.g. `进度: 延迟测速 4051/8192 (49%)`) showing how many IPs have been tested out of the total, instead of flooding the log with per-IP progress.
*   **GitHub Mirror Download**: Optional direct / ghfast / ghproxy / custom mirror when downloading the core on first run, improving success rate where GitHub access is restricted.
*   **Partial Results Saved on Stop**: When the speed test is stopped midway, the already-measured results are sorted and saved — no progress is lost.
*   **Packet-Loss Filter**: Supports a `-tlr` packet-loss-rate cap, applied in both default and advanced modes.
*   **ucode Backend**: The backend has been migrated from Lua to ucode, with a built-in Alibaba Cloud DNS HMAC-SHA1 signer — no extra Lua dependencies required.
*   **Broad Integrations**: The best IP can be automatically applied to SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.

## Feature Details

### UI Pages

The plugin provides three pages under LuCI → Services → CloudflareSpeedTest:

*   **Plugin Settings**: Three tabs — Basic / Crontab / Advanced — with a Start/Stop button, a 3-second polled status bar, a read-only Best IP area, and history line charts for latency and download speed.
*   **Third Party Settings**: Tabs appear on demand for each proxy tool installed on the router, letting you choose which nodes / domains / DNS services receive the best IP.
*   **Logs**: Incrementally fetches the speed-test log, with an optional 5-second auto-refresh. Overall progress (tested / total) is shown inline while a test is running.

### Speed-Test Parameters & Modes

*   **Default mode**: Uses `-tl 200 -tll 40 -tlr 0.2 -dn 5` — latency cap, latency lower bound, packet-loss-rate cap, and the number of download-speed-test nodes.
*   **Advanced mode (Advanced toggle)**: Exposes thread count `-n`, latency test time `-t`, download test time `-dt`, port `-tp`, `-dd` to disable download testing, and `-httping` + `-cfcolo` for HTTP-based latency testing.
*   **IP source**: Built-in IPv4 / IPv6 lists or a custom IP file, with an optional `-allip` flag to scan every /24 subnet.

### How the Best IP Is Applied

After a speed test completes, the best IP is **written automatically** to the integrations below — no manual "apply" step:

*   **HOST**: Writes to `/etc/hosts` and reloads dnsmasq.
*   **MosDNS**: Writes `cloudflare_ip` to `/etc/config/mosdns`, optionally restarting OpenClash.
*   **astra-dns**: Rewrites its YAML config and hot-reloads via SIGHUP.
*   **Alibaba Cloud DDNS**: Auto-selects A / AAAA records and supports multiple IPs.
*   **Proxy nodes**: Writes the `server` / `address` field of ssr / passwall / passwall2 / bypass / vssr.

> Note: The plugin does not modify `ip route` or network routes — the best IP takes effect only through hosts / DNS / proxy nodes.

### Scheduled Tasks

Built-in cron scheduling supports a 1–24 hour interval or a custom cron expression. The `init.d` script updates the crontab idempotently, only when it changes.

### Proxy Mode (Temporary Switch During Tests)

To prevent speed-test traffic from being polluted by the local proxy, the proxy tool's run mode is switched temporarily during a test and restored afterward:

*   **HOLD (`nil`)**: Leave the current proxy mode untouched.
*   **GFW List (`gfw`, default)**: Speed-test IPs go direct; GFW-listed traffic still goes through the proxy.
*   **CLOSE (`close`)**: Disable the proxy during the test, then restore.

### Results & History

Results are saved to `/tmp/CloudflareSpeedTest/result.csv` with 10 rolling historical versions kept; the Best IP area shows the last 100 lines, and the history charts plot the most recent 10 results for latency and download speed.

## Installation

1.  Download the latest `.ipk` or `.apk` file from [Releases](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases).
2.  Install it on your router:
    ```bash
    opkg install luci-app-cloudflarespeedtest_*.ipk
    ```
3.  Go to LuCI -> Services -> CloudflareSpeedTest to configure.

## Screenshots

![Overview](screenshots/overview.png)
![History Chart](screenshots/chart.png)

## Build

```bash
# Compile package only
make package/luci-app-cloudflarespeedtest/compile V=99

# Compile full image
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-cloudflarespeedtest..... for LuCI ----> save
make V=99
```

## Acknowledgements

*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)
