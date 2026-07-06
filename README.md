# luci-app-passwall-speedtest

[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/stevenjoezhang/luci-app-cloudflarespeedtest/build.yml?style=for-the-badge&logo=GitHub)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/actions/workflows/build.yml)
[![GitHub release (latest by date)](https://img.shields.io/github/v/release/stevenjoezhang/luci-app-cloudflarespeedtest?style=for-the-badge)](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases)

[中文说明](README.CN.md)

**luci-app-passwall-speedtest** is a LuCI application for OpenWrt that selects the best Cloudflare IP by probing candidate IPs **through your existing [PassWall](https://github.com/xiaorouji/openwrt-passwall) nodes**. It writes each candidate IP into a passwall node's `address`, spins up a local SOCKS via passwall, and measures HTTP HEAD latency (`time_pretransfer`); the fastest IP is then written back to the passwall node(s) and other integrations.

> This is a refactor of the original `luci-app-cloudflarespeedtest`: the standalone `CloudflareSpeedTest` binary download path has been removed. The test now runs entirely through passwall — no external test binary is downloaded or bundled. Only latency is measured (no download bandwidth).

## Requirements

*   **PassWall** (`openwrt-passwall`) must be installed — the test drives `/usr/share/passwall/app.sh run_socks`. If passwall is missing, the test reports an error and aborts.
*   **curl** (hard dependency) for the latency probe.
*   At least one CF-CDN-fronted passwall node (VLESS / VMess / Trojan / SS …). SOCKS-type passwall nodes cannot be used as test nodes (their `address` IS the SOCKS server).

## Features

*   **Node-Based Latency Test**: Probes candidate Cloudflare IPs through your passwall node chain — finds the best CF IP *as seen from your proxy's egress*.
*   **Multi-Threaded Workers**: Passwall nodes selected in the Third-Party tab run as parallel workers — each tests all candidate IPs through its own chain and gets its own best IP written back. Concurrency is capped by `node_test_threads`.
*   **Fail-Fast Multi-Probe**: Each IP is probed `node_test_probes` times; if any probe fails, the IP is discarded immediately. Only IPs that succeed on all probes are kept, so the result is a stable one.
*   **Proxy Integration**: Writes the best IP back to ssr / passwall / passwall2 / bypass / vssr nodes, and to HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.
*   **Visual Charts**: History chart for latency trends (download-speed chart removed — node mode is latency-only).
*   **Improved UI & Logs**: Redesigned status display; per-IP log lines like `进度: 走节点测速 [node] 5/30 (16%) - 1.2.3.4 延迟 87ms 丢包 0.00 [保留]`.
*   **Partial Results Saved on Stop**: Stopping mid-test triggers a trap that cleans up SOCKS, restores node addresses, and keeps the previous result if nothing new was measured.
*   **Broad Integrations**: The best IP can be automatically applied to SSR+ / Passwall / PassWall2 / Bypass / Vssr / HOST / MosDNS / astra-dns / Alibaba Cloud DDNS.

## UI Pages

Three pages under LuCI → Services → PassWall Speed Test:

*   **Plugin Settings**: Basic (test params) + Crontab tabs, with a Start/Stop button, a 3-second polled status bar, a read-only Best IP area, and a latency history chart.
*   **Third Party Settings**: Tabs appear on demand for each proxy tool installed on the router. The passwall nodes selected here double as the parallel workers.
*   **Logs**: Incrementally fetches the test log, with an optional 5-second auto-refresh.

## Test Parameters

*   **IP list source**: Built-in IPv4 / IPv6 lists or a custom IP file, with an optional "scan all IPs in each /24" flag.
*   **Latency cap / lower bound / packet-loss cap** (`tl` / `tll` / `tlr`): Discard candidate IPs outside these thresholds (ms / ms / 0–1).
*   **Passwall node to test through**: Single-node fallback when no passwall workers are selected.
*   **Probe URL**: URL probed via the node's local SOCKS (HTTP HEAD). Defaults to Google `generate_204`.
*   **Max IPs to test**: Cap on candidate IPs tested per worker.
*   **Probe timeout**: Per-IP curl `--max-time` (seconds).
*   **Probes per IP**: Number of curl probes per IP (all must succeed or the IP is discarded).
*   **Max parallel workers**: Concurrency cap for multi-node mode (0 = all).

## How the Best IP Is Applied

After a test completes:

*   Each passwall worker node gets its own best IP written to `passwall.<node>.address`.
*   The global lowest-latency IP is written automatically to: HOST (`/etc/hosts`), MosDNS, astra-dns, Alibaba Cloud DDNS, and the `server`/`address` field of ssr / passwall / passwall2 / bypass / vssr nodes.

> Note: The plugin does not modify `ip route`. The best IP takes effect through hosts / DNS / proxy nodes.

## Scheduled Tasks

Built-in cron scheduling supports a 1–24 hour interval or a custom cron expression. The `init.d` script updates the crontab idempotently, only when it changes.

## Results & History

Results are saved to `/tmp/passwall-speedtest/result.csv` with 10 rolling historical versions kept; the Best IP area shows the last 100 lines, and the latency chart plots the most recent 10 results.

## Installation

1.  Download the latest `.ipk` or `.apk` file from [Releases](https://github.com/stevenjoezhang/luci-app-cloudflarespeedtest/releases).
2.  Install it on your router:
    ```bash
    opkg install luci-app-passwall-speedtest_*.ipk
    ```
3.  Go to LuCI → Services → PassWall Speed Test to configure.
    > Upgrading from the old `luci-app-cloudflarespeedtest`: the UCI config was renamed to `passwall-speedtest`, so previous settings are **not** migrated — reconfigure in the LuCI page. You may delete the old `/etc/config/cloudflarespeedtest`.

## Build

```bash
# Compile package only
make package/luci-app-passwall-speedtest/compile V=99

# Compile full image
make menuconfig
#choose LuCI ---> 3. Applications  ---> <*> luci-app-passwall-speedtest..... for LuCI ----> save
make V=99
```

## Acknowledgements

*   [openwrt-passwall](https://github.com/xiaorouji/openwrt-passwall)
*   [CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest) (the IP list format is reused)
*   [mingxiaoyu/luci-app-cloudflarespeedtest](https://github.com/mingxiaoyu/luci-app-cloudflarespeedtest)