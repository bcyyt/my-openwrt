# User Instruction Memory

This file records user instructions, preferences, and teachings for reference in future interactions.

## Format

### User Instruction Entry
User instruction entries should follow this format:

[User Instruction Summary]
- Date: [YYYY-MM-DD]
- Context: [Mentioned scenario or time]
- Instructions:
  - [Content of user teaching or instruction, described line by line]

### Project Knowledge Entry
Entries discovered by the Agent during task execution should follow this format:

[Project Knowledge Summary]
- Date: [YYYY-MM-DD]
- Context: Discovered by Agent while performing [specific task description]
- Category: [Operations & Deployment|Build Methods|Testing Methods|Troubleshooting & Debugging|Workflow & Collaboration|Environment Configuration]
- Instructions:
  - [Specific knowledge points, described line by line]

## Deduplication Strategy
- Before adding a new entry, check for similar or identical instructions.
- If a duplicate is found, skip the new entry or merge it with the existing one.
- When merging, update the context or date information.
- This helps avoid redundant entries and keeps the memory file tidy.

## Entries

[Router SSH and package install]
- Date: 2026-10-13
  - Context: User instructed to use cs.bcyyt.top port 22 over IPv6
  - Category: Operations & Deployment
  - Instructions:
  - SSH is `root@cs.bcyyt.top` port `22` over IPv6. The host is IPv6-only; do not force `-4`.
  - Fallback: NATFRP `root@ak.bcyyt.top` port `23232`, or PPPoE WAN IPv4 on dropbear port `22`. WAN port `2323` is closed.
  - There is no SFTP; copy APKs with `ssh cat > /tmp/*.apk` then `apk add /tmp/*.apk`.
  - Keep overlay plugin APKs on the data disk for syskeep restore. `/etc/syskeep/custom-apks.txt` often lands as `.apk-new` after flash and must be copied over the live file.

[IPTV auth path after flash]
- Date: 2026-10-11
- Context: Discovered by Agent while diagnosing auth_ok=false after keep-upgrade flash
- Category: Troubleshooting & Debugging
- Instructions:
  - IPTV auth (`182.137.9.86:8080`) only works via `eth2`/`wan2`. The PPPoE WAN times out to that host.
  - After flash, `wan2` can have a DHCP address while `ip neigh show dev eth2` for `10.107.144.1` is still FAILED. Python then logs `Host is unreachable`.
  - Gateway ping may stay 100% loss even after TCP auth works. Check `ip neigh` REACHABLE and `curl --interface eth2 -m 8 http://182.137.9.86:8080/iptvepg/platform/auth.jsp`.
  - When ARP is ready, restart or touch `/tmp/iptv-auth-runnow`. Status is `/var/log/iptv-auth/status.json`.

[SakuraFrp restore]
- Date: 2026-10-11
- Context: Discovered by Agent while restoring natfrp after keep-upgrade flash
- Category: Operations & Deployment
- Instructions:
  - `luci-app-natfrp` is a third-party APK, not in OpenWrt feeds. Official x86_64 package: `https://nya.globalslb.net/natfrp/client/launcher-openwrt/3.1.8/luci-app-natfrp-3.1.8-r6-x86_64.apk`
  - Keep that APK on `/mnt/data/syskeep/apks/` and a line in `/etc/syskeep/custom-apks.txt`. Overlay-pkgs must list `luci-app-natfrp`.
  - After flash, `/etc/config/natfrp` and `/etc/natfrp/config.json` can remain while `/usr/bin/natfrp-service` is gone. Install the APK then `/etc/init.d/natfrp restart`.

[Tokens and credits]
- Date: 2026-10-13
- Context: User instructed while fixing CPU temperature bias
- Instructions:
  - If model/API tokens are exhausted, pause the task.
  - Do not spend 积分 / paid credits to continue.

[statusmon build and packaging]
- Date: 2026-10-13
- Context: Discovered by Agent while adding the resident sysmon sampler
- Category: Build Methods
- Instructions:
  - Build only selected packages (avoids repacking other same-version plugins): `./packaging/build-apks.sh iptv-auth` (several names = subset, no args = all; filter helper `want()` near the top). Verify a built APK payload without installing on the router: create stub packages for its deps (`apk mkpkg -I name:<dep>`), then `apk add --root /tmp/verify --allow-untrusted --initdb --force-non-repository --no-scripts /tmp/stubs/*.apk <pkg>.apk` and `cmp` the extracted file against the repo source.
  - `apk` runs `post-upgrade` (not `post-install`) on upgrades. mkpkg must register both: `-s post-install:<script> -s post-upgrade:<script>`, otherwise install-time init enable/start never fires on upgrade.
- Project Knowledge (Operations & Deployment):
  - statusmon system metrics are sampled by a procd-managed daemon `/etc/init.d/statusmon-sampler` (`/usr/bin/statusmon-sampler`, default 2s) writing `/tmp/statusmon-snap`; the CGI prefers this snapshot and falls back to inline sampling when missing/stale (>12s).

[Router syslog DNS noise]
- Date: 2026-10-14
- Context: Discovered by Agent while investigating many `127.0.0.1` lines in logread
- Category: Troubleshooting & Debugging
- Instructions:
  - `dhcp.@dnsmasq[0].dns_redirect='1'` inserts an nftables rule (`udp dport 53 redirect to :53`, comment "DNSMASQ HIJACK", from `/etc/init.d/dnsmasq`) that rewrites LAN DNS client source addresses to `127.0.0.1` in dnsmasq logs. So `from 127.0.0.1` in `dnsmasq[...] query/reply/forwarded` lines means a LAN device, not localhost.
  - `dhcp.@dnsmasq[0].logqueries='1'` makes dnsmasq log every query; disable with `uci set dhcp.@dnsmasq[0].logqueries='0'` + `uci commit dhcp` + `/etc/init.d/dnsmasq restart`.
  - The old atkmon DNS module depended on logqueries and `atkmon-setup` re-enabled it (via `atkmon.main.dns_log`). Both the module and the setup hook were removed in luci-app-atkmon 1.0.6-r0, so `atkmon-setup` no longer touches dnsmasq logqueries.
  - statusmon traffic classification via dnsmasq `nftset=` is independent of `logqueries`; it keeps working when query logging is off.
  - dnsmasq only emits `DHCPACK/DHCPNAK` lines to syslog when `dhcp.@dnsmasq[0].logdhcp='1'`. The statusmon「日志」页 DHCP 类别依赖它，post-install 会按需开启（仅 DHCP，不含 DNS 查询）。
  - 真实 dnsmasq DHCP 行在 tag 与事件名之间带一个数字事务 ID：`dnsmasq-dhcp[1]: <txid> DHCPACK(br-lan) <ip> <mac> <name>`。匹配正则须写成 `(?:\d+ )?DHCPACK`，否则 DHCP 日志永远采不到（statusmon 4.40 修复）。
  - statusmon-attack 曾在 nft `input` 链对 WAN 新连接 `log prefix "statusmon-attack: " limit rate 20/second`，导致系统日志被 `IN=pppoe-wan` 行刷屏（占 logread 约 80%，看起来"全是 pppoe"）。4.39 移除该 log 规则与端口探测采集，攻击记录仅保留登录爆破来源；排查此类刷屏先看 `nft list chain inet statusmon_attack input`。

[statusmon attack data persistence]
- Date: 2026-10-14
- Context: Discovered by Agent while merging atkmon into luci-app-statusmon
- Category: Operations & Deployment
- Instructions:
  - `/var` is a symlink to `/tmp` (tmpfs), so anything under `/var/lib` is lost on reboot. To persist attack records/logs, the collector mirrors them to the overlay: `/etc/statusmon/attack-state.json` (records, max 2000) and `/etc/statusmon/attack-log.jsonl` (auth + PPPoE events, max 50000). `/var/lib/statusmon-attack/` holds the live snapshot/state only.
  - Manual clear is asynchronous: LuCI writes `/var/lib/statusmon-attack/cmd.json` (`{"records":true}` or `{"log":true}`), and the collector consumes it at the next loop, clears the in-memory state, then flushes the mirror.
- busybox `sleep` in OpenWrt only accepts integer seconds; `sleep 0.25` fails instantly. Poll loops must use `sleep 1` (or `nixio.nanosleep`).

[iptv-auth full uninstall / fresh install]
- Date: 2026-10-15
- Context: Discovered by Agent while doing a full uninstall + fresh install test of iptv-auth 2.3.33 on the router
- Category: Troubleshooting & Debugging
- Instructions:
  - `python3` is a shared dependency: both `iptv-auth` and `luci-app-statusmon` depend on it, so `apk del python3` refuses (`not removed due to: iptv-auth luci-app-statusmon`). A true full uninstall must also remove `luci-app-statusmon` first, then reinstall it (its APK is kept at `/tmp/luci-app-statusmon-4.40.apk`; it is not in the repo `packages/` dir).
  - pip-installed modules (`requests`, `urllib3`, `certifi`, `charset_normalizer`, `idna`) under `/usr/lib/python3.14/site-packages` are NOT apk-owned; `apk del python3` leaves them behind. Remove them for a clean test, otherwise a reinstalled python3 still imports `requests` and masks a missing dependency.
  - APK-owned conffiles survive purge as `.apk-new` leftovers and `/etc/sysctl.d/15-iptv-auth.conf` is kept; generated runtime files (`/www/*.m3u`, `/www/PL.xml(.gz)`, `/www/logo`, `/var/log/iptv-auth`) are not package-owned either. The router has no SFTP: upload APKs with `ssh root@... 'cat > /tmp/x.apk'`.
  - After `apk add`/`apk upgrade` the running daemon is NOT restarted; you must `apk add --allow-untrusted /tmp/<pkg>.apk` then `/etc/init.d/iptv-auth restart` (and restart the `statusmon-*` services after restoring statusmon).
  - Fresh-install chain to verify: auth 200 -> 125 channels -> 4 M3U (`/www/{Lan,LanReplay,WanPlay,WanReplay}.m3u`) -> logos -> EPG `/www/PL.xml(.gz)` (~11 min, 125 channels) -> rtp2httpd live on `:23234` and RTSP replay proxy on `[::]:554`. Status is `/var/log/iptv-auth/status.json` (`auth_ok`, `channels`).

[iptv-replayd C daemon: timezone and packaging]
- Date: 2026-10-16
- Context: Discovered by Agent while splitting the 554 RTSP replay proxy out of iptv-auth.py into a static-musl C daemon
- Category: Troubleshooting & Debugging / Environment Configuration
- Instructions:
  - This router's `/etc/localtime` is a dangling symlink to missing `/tmp/localtime`; the real timezone lives in `/etc/TZ` (`CST-8`). Upstream static musl only honors `TZ`/localtime and falls back to UTC, so a statically linked C daemon logs 8 hours behind busybox/Python. Fix in C: read `/etc/TZ`, `setenv("TZ", ...)`, then `tzset()` before using `localtime_r`.
  - The 554 replay proxy is `src/iptv-replayd/iptv-replayd.c`; rebuild both arches with `packaging/iptv-replayd/build.sh` (musl cross toolchain) then `packaging/build-apks.sh`. Both x86_64/aarch64 binaries ship inside the `noarch` iptv-auth package under `/usr/lib/iptv-auth/`, and init.d selects one via `uname -m` (do not copy to `/usr/bin`).
  - Runtime state handoff is `/tmp/iptv-replayd.state` written by `iptv-auth.py`; side processes (`--apply-route`) also refresh it with an empty `rtsp_source_ip`, so `write_replayd_state()` must preserve the previous on-disk value when the current one is empty.
  - Upstream IPTV portal rejects RTSP catchup (playseek) requests whose `programend` is in the future, replying `RTSP/1.0 562`; the boundary is exactly local-now (end <= now works, end >= now+1 fails). rtp2httpd's `(e)` placeholder can land at now+1, so the failure is intermittent (external catchup via `cs.bcyyt.top:2000/WanPlay.m3u` fails while live works; rtp2httpd logs `Server returned error code 562` / `Failed to receive response`). `iptv-replayd` clamps `programend` to now-2 before forwarding; diagnose by scanning playseek end offsets around 0 via `http://127.0.0.1:23234/rtsp/192.168.10.1:554/PLTV/<ch>.smil?playseek=<b>-<e>`.

[IPTV control-plane HTTP/EPG performance]
- Date: 2026-10-16
- Context: Discovered by Agent while optimizing iptv-auth EPG/logo fetching and diagnosing why a keep-alive client felt slower
- Category: Troubleshooting & Debugging / Operations & Deployment
- Instructions:
  - A reused keep-alive TCP socket MUST set `TCP_NODELAY`. Without it, the small request line/headers plus delayed ACK trigger Nagle stalls (~40-100 ms/request); serial EPG was 106 ms/req with keep-alive vs 18 ms/req with the old connection-per-request urllib path, i.e. keep-alive made it slower until `TCP_NODELAY` was set.
  - The IPTV portal caches EPG per `(channelcode, timedata)`. Cold fetch is ~2.8 s/channel serial; repeats are near-instant, so any A/B timing test MUST account for cache warming (running serial first flatters the parallel run by ~16x; the true cold parallel speedup at 8 workers is only ~1.6x).
  - Portal concurrency sweet spot: ~4-8 workers. `fetch_workers>=12` collapses (per-account throttling), so keep the default at 4 (config `iptv-auth.main.fetch_workers`, clamped to 1..16).
  - The concurrent-stream ceiling is `rtp2httpd --maxclients` (`-m`, upstream default 5), NOT `-w` (worker processes). Extra concurrent stream requests get `503 Service Unavailable` (rtp2httpd's own HTML body). Verified globally enforced: `-m 5` -> 5x200/5x503 on 10 concurrent; `-m 20` -> 10x200/0x503. It is now exposed in the LuCI config page and UCI as `iptv-auth.main.rtp2h_maxclients` (init.d passes `-m`, falls back to 5). This ceiling is unrelated to `iptv-replayd`.
  - `dmesg | grep 562` false-positives: the `statusmon-attack` firewall log prints source ports (`SPT=56232` etc.). Count real RTSP 562 only in `/var/log/iptv-auth/iptv-auth.log`.

[IPTV portal same-name channels are NOT duplicates]
- Date: 2026-10-17
- Context: Discovered by Agent while investigating a report that subscribing to `http://ak.bcyyt.top:23234/playlist.m3u` shows "源1/源2" for some channels
- Category: Troubleshooting & Debugging
- Instructions:
  - The portal `frameset_builder.jsp` legitimately returns several channels with the SAME `ChannelName` but different `igmp://` group addresses and RTSP ids (raw 317 entries -> 13 same-name names; 11 survive the PIP/keyword filters, e.g. `CCTV5高清`, `生活时尚`, and 9 `*卫视4K`). These are intentional separate streams (e.g. an HD vs a 4K feed), and BOTH must be kept. Do NOT dedup by channel name in `fetch_channels` -- doing so drops valid sources.
  - rtp2httpd (`src/m3u.c` `find_unique_service_name`) disambiguates a repeated service name by appending `/2`; players (Ku9 etc.) group entries by `tvg-name`, so the two same-named entries render as "源1/源2". That is the expected multi-source display, not a bug.
  - Both streams were verified playable via `http://127.0.0.1:23234/rtp/<igmp>`; the first-listed stream of each pair is the higher-bitrate one (~28 MB/6s vs ~18.5 MB/6s for the 4K pairs). Lookup of the same-name set: scan the raw portal text for `ChannelName=` duplicates.

[IPTV replay position jump is client-driven, not server state]
- Date: 2026-10-17
- Context: Discovered by Agent while investigating "replay sometimes jumps to an earlier watched position then back"
- Category: Troubleshooting & Debugging
- Instructions:
  - The catchup chain is fully stateless: `iptv-replayd` keeps no playback position, it only rewrites `playseek` into `programbegin/programend` (clamping a future end to now-2); rtp2httpd creates a fresh service/upstream per request. Verify by grepping `/var/log/iptv-auth/iptv-auth.log` for `代理: 回看 <ch> | <begin>~<end>`: each switch of position is a separate client request.
  - Diagnose a reported jump by (1) listing the client's playseek sequence, (2) checking the program boundary in `/www/PL.xml` (attributes are `channel="<tvg-id>" start="..." stop="..."`), and (3) capturing two positions and comparing the first video PTS (90 kHz) to the requested delta. A GOP-align offset of ~2 s (content starts slightly before the requested second) is normal.
  - A real server-side jump would show a backward PTS discontinuity inside ONE connection. Alternating -0.02 s deltas are normal B-frame reordering; allow for them when checking.
  - In the observed case, Ku9 restores an old resume point and then re-requests the actual position (e.g. `19:30:00` then 4 s later `19:50:41`), which is client resume/seek behavior. Do not add server-side seek state or clamping of backward seeks to "fix" it.
  - At the natural end of a catchup program the upstream RTSP server sends `ANNOUNCE` ("stream may be ending") and closes. The player (Ku9) then immediately re-requests the SAME catchup URL from the program start (observed: 90-min program finished 11:34:01, identical `playseek=...` re-request at 11:34:01, live URL opened at 11:34:48). That replay-from-start window is what looks like "jumps back to an already watched position, then returns to normal". rtp2httpd/replayd are stateless here; the retry is client-initiated. Confirm by matching the `catchup?playseek=` line in `logread` with the `代理: 回看` line in the auth log. A server-side workaround (treating a just-ended range as live) would break legitimate catchup of recently ended programs, so treat this as player behavior.
