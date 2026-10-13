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
