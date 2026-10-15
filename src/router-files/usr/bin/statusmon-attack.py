#!/usr/bin/env python3
# statusmon attack collector: parse syslog + wan snapshot into /var/lib/statusmon-attack

import ipaddress
import json
import os
import re
import subprocess
import time
import sys
from collections import defaultdict

DIR = "/var/lib/statusmon-attack"
SNAP = DIR + "/snapshot.json"
STATE = DIR + "/state.json"
EVENTS = DIR + "/events.jsonl"
CMD = DIR + "/cmd.json"
# 攻击记录/日志持久化到 overlay（/var 是 tmpfs，重启即失）；镜像文件不随包卸载
PERSIST_STATE = "/etc/statusmon/attack-state.json"
PERSIST_LOG = "/etc/statusmon/attack-log.jsonl"
MAX_RECORDS = 2000
# 持久化日志按类别限长（防单类刷爆 flash）；无固定短期过期
LOG_CAP = {"attack": 30000, "login": 20000, "dhcp": 20000, "pppoe": 5000}
HOUR_KEEP = 168
INTERVAL = 5

RE_DROPBEAR = re.compile(
    r"dropbear.*(?:Bad password attempt for '([^']*)'|Login attempt for nonexistent user).*from ([0-9a-fA-F:.]+)"
)
RE_DROPBEAR_OK = re.compile(
    r"dropbear.*(?:Password|Pubkey) auth succeeded for '([^']*)' from ([0-9a-fA-F:.]+)"
)
RE_LUCI = re.compile(r"luci: failed login(?: on \S+)?(?: for (\S+))? from ([0-9a-fA-F:.]+)")
RE_LUCI_OK = re.compile(r"luci: accepted login(?: on \S+)?(?: for (\S+))? from ([0-9a-fA-F:.]+)")
RE_PPPOE_DOWN = re.compile(r"(Modem hangup|Connection terminated|Interface 'wan' is now down|Timeout waiting for PADO)")
# dnsmasq 在 tag 与事件名之间可能带一个数字事务 ID，例如：
#   dnsmasq-dhcp[1]: 4239439749 DHCPACK(br-lan) 192.168.10.108 b8:27:.. name
RE_DHCPACK = re.compile(r"dnsmasq-dhcp\[\d+\]: (?:\d+ )?DHCPACK\(\S+\) (\S+) (\S+)(?: (\S+))?")
RE_DHCPNAK = re.compile(r"dnsmasq-dhcp\[\d+\]: (?:\d+ )?DHCPNAK\(\S+\) (\S+) (\S+)(?: (\S+))?")


def sh(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, errors="replace").strip()
    except Exception:
        return ""


def load_json(path, default):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except Exception:
        return default


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, path)


def uci_get(key):
    return sh(["uci", "-q", "get", key])


def lan_nets():
    nets = []
    text = sh(["ip", "-o", "addr", "show", "dev", "br-lan"])
    for m in re.finditer(r"inet6? (\S+)", text):
        try:
            nets.append(ipaddress.ip_network(m.group(1), strict=False))
        except ValueError:
            pass
    for extra in ("192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12", "127.0.0.0/8",
                  "fe80::/10", "fc00::/7", "::1/128"):
        nets.append(ipaddress.ip_network(extra))
    return nets


def parse_ip(s):
    s = (s or "").strip().strip("[]")
    if s.count(":") == 1 and "." in s:
        s = s.rsplit(":", 1)[0]
    try:
        return str(ipaddress.ip_address(s))
    except ValueError:
        if ":" in s:
            try:
                return str(ipaddress.ip_address(s.rsplit(":", 1)[0].strip("[]")))
            except ValueError:
                return ""
        return ""


def is_lan(ip, nets):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return True
    return any(addr in n for n in nets)


def parse_sport(s):
    s = (s or "").strip().strip("[]")
    if s.count(":") == 1 and "." in s:
        rest = s.rsplit(":", 1)[1]
        try:
            n = int(rest)
            if 1 <= n <= 65535:
                return n
        except ValueError:
            pass
    return 0


def ssh_listen_port():
    raw = uci_get("dropbear.@dropbear[0].Port") or "22"
    try:
        n = int(raw)
        if 1 <= n <= 65535:
            return n
    except ValueError:
        pass
    return 22


def add_port(row, port):
    try:
        port = int(port)
    except (TypeError, ValueError):
        return
    if port <= 0:
        return
    lst = row.setdefault("ports", [])
    if port not in lst:
        lst.append(port)


def add_sport(row, sport):
    try:
        sport = int(sport)
    except (TypeError, ValueError):
        return
    if sport <= 0:
        return
    lst = row.setdefault("sports", [])
    if sport not in lst:
        lst.append(sport)
    if len(lst) > 12:
        del lst[:-12]


def hour_key(ts):
    return str(int(ts) // 3600 * 3600)


def auth_ports_from_events(events):
    dports = {}
    sports = {}
    for e in events or []:
        if e.get("type") != "auth":
            continue
        ip = e.get("ip")
        if not ip:
            continue
        p = e.get("port")
        if p == 2323:
            p = 22
        if p:
            lst = dports.setdefault(ip, [])
            if p not in lst:
                lst.append(p)
        sp = e.get("sport")
        if sp:
            sl = sports.setdefault(ip, [])
            if sp not in sl:
                sl.append(sp)
    return dports, sports


def prune_hourly(hourly, now):
    cut = now - HOUR_KEEP * 3600
    return {k: v for k, v in hourly.items() if int(k) >= cut}


def append_event(events, ev, now):
    events.append(ev)
    # 按类别分别限长，避免攻击事件洪泛把登录/DHCP/PPPoE 日志挤掉
    cat = ev.get("cat")
    cap = LOG_CAP.get(cat)
    if cap:
        n = 0
        idx = []
        for i, e in enumerate(events):
            if e.get("cat") == cat:
                idx.append(i)
        if len(idx) > cap:
            drop = set(idx[:len(idx) - cap])
            events[:] = [e for i, e in enumerate(events) if i not in drop]


def log_events(st):
    # 持久化日志：攻击 / 登录 / DHCP / PPPoE，按类别分别限长
    # （旧版本遗留的端口探测事件 type=probe 一并过滤，避免写入）
    rows = [e for e in st.get("events") or []
            if e.get("type") != "probe"
            and e.get("cat") in ("attack", "login", "dhcp", "pppoe")]
    out = []
    for cat in ("attack", "login", "dhcp", "pppoe"):
        bucket = [e for e in rows if e.get("cat") == cat]
        out.extend(bucket[-LOG_CAP.get(cat, 10000):])
    out.sort(key=lambda e: int(e.get("ts") or 0))
    return out


def ev_key(e):
    return (e.get("ts"), e.get("cat"), e.get("type"), e.get("svc"),
            e.get("ip"), e.get("mac"), e.get("port"), e.get("sport"), e.get("user"))


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    os.replace(tmp, path)


def load_persist(st):
    meta = load_json(PERSIST_STATE, None)
    if isinstance(meta, dict):
        saved = meta.get("attack")
        if isinstance(saved, dict):
            for ip, row in saved.items():
                st["attack"].setdefault(ip, row)
        if not st.get("cursor"):
            st["cursor"] = meta.get("cursor") or ""
    seen = set()
    for e in st.get("events") or []:
        seen.add(ev_key(e))
    evs = []
    try:
        with open(PERSIST_LOG, "r") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    evs.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        evs = []
    for e in evs:
        k = ev_key(e)
        if k not in seen:
            seen.add(k)
            append_event(st["events"], e, None)


def flush_persist(st, last):
    recs = st.get("attack") or {}
    sig_r = "%d:%d:%d" % (
        len(recs),
        sum(int(r.get("count") or 0) for r in recs.values()),
        max((int(r.get("last_ts") or 0) for r in recs.values()), default=0),
    )
    if sig_r != last.get("r"):
        write_json(PERSIST_STATE, {"cursor": st.get("cursor") or "", "attack": recs})
        last["r"] = sig_r
    logev = log_events(st)
    sig_l = "%d:%d" % (len(logev), int(logev[-1].get("ts") or 0) if logev else 0)
    if sig_l != last.get("l"):
        write_jsonl(PERSIST_LOG, logev)
        last["l"] = sig_l


def handle_cmd(st):
    if not os.path.exists(CMD):
        return False
    cmd = load_json(CMD, {})
    try:
        os.remove(CMD)
    except OSError:
        pass
    if not isinstance(cmd, dict):
        return False
    if cmd.get("records"):
        st["attack"] = {}
    if cmd.get("log"):
        st["events"] = []
    return True


def bump(hourly, ts, field, n=1):
    k = hour_key(ts)
    row = hourly.setdefault(k, {"auth": 0, "pppoe": 0})
    row[field] = int(row.get(field) or 0) + n


def wan_status():
    raw = sh(["ubus", "call", "network.interface.wan", "status"])
    data = {}
    if raw:
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            data = {}
    ipv4 = ""
    ipv6 = ""
    for a in data.get("ipv4-address") or []:
        ipv4 = a.get("address") or ipv4
    for a in data.get("ipv6-address") or []:
        ipv6 = a.get("address") or ipv6
    return {
        "up": bool(data.get("up")),
        "uptime": int(data.get("uptime") or 0),
        "ipv4": ipv4,
        "ipv6": ipv6,
        "device": data.get("l3_device") or data.get("device") or "",
    }


def is_real_attack(row, now=None):
    return int(row.get("auth_count") or 0) > 0


def attack_tag(summary, ip, now):
    row = summary.get(ip) or {}
    row["auth_ts"] = [t for t in row.get("auth_ts") or [] if now - t <= 600][-20:]
    summary[ip] = row


def parse_line(line, st, now, nets):
    events = st["events"]
    hourly = st["hourly"]
    summary = st["attack"]
    pppoe_ev = st["pppoe_events"]

    m = RE_DROPBEAR.search(line)
    if m:
        ip = parse_ip(m.group(2))
        user = m.group(1) or ""
        # 登录日志（全部来源，含失败）；攻击记录仅取非 LAN 来源
        append_event(events, {"ts": now, "cat": "login", "type": "fail", "svc": "ssh",
                              "ip": ip, "user": user, "sport": parse_sport(m.group(2))}, now)
        if ip and not is_lan(ip, nets):
            dport = ssh_listen_port()
            sport = parse_sport(m.group(2))
            ev = {"ts": now, "cat": "attack", "type": "auth", "svc": "ssh", "ip": ip, "user": user, "port": dport, "sport": sport}
            append_event(events, ev, now)
            bump(hourly, now, "auth")
            row = summary.setdefault(ip, {"ip": ip, "count": 0, "auth_count": 0,
                                          "ports": [], "first_ts": now, "last_ts": now, "auth_ts": []})
            row["count"] += 1
            row["auth_count"] += 1
            row["last_ts"] = now
            row["auth_ts"].append(now)
            add_port(row, dport)
            add_sport(row, sport)
            attack_tag(summary, ip, now)
        return

    m = RE_LUCI.search(line)
    if m:
        ip = parse_ip(m.group(2))
        append_event(events, {"ts": now, "cat": "login", "type": "fail", "svc": "luci",
                              "ip": ip, "user": m.group(1) or ""}, now)
        if ip and not is_lan(ip, nets):
            dport = 443 if "https" in line.lower() else 80
            ev = {"ts": now, "cat": "attack", "type": "auth", "svc": "luci", "ip": ip, "port": dport}
            append_event(events, ev, now)
            bump(hourly, now, "auth")
            row = summary.setdefault(ip, {"ip": ip, "count": 0, "auth_count": 0,
                                          "ports": [], "first_ts": now, "last_ts": now, "auth_ts": []})
            row["count"] += 1
            row["auth_count"] += 1
            row["last_ts"] = now
            row["auth_ts"].append(now)
            add_port(row, dport)
            attack_tag(summary, ip, now)
        return

    # 登录成功事件（供「日志」页展示，不计入攻击记录）
    m = RE_DROPBEAR_OK.search(line)
    if m:
        ev = {"ts": now, "cat": "login", "type": "ok", "svc": "ssh",
              "ip": parse_ip(m.group(2)), "user": m.group(1) or "", "sport": parse_sport(m.group(2))}
        append_event(events, ev, now)
        return

    m = RE_LUCI_OK.search(line)
    if m:
        ev = {"ts": now, "cat": "login", "type": "ok", "svc": "luci",
              "ip": parse_ip(m.group(2)), "user": m.group(1) or ""}
        append_event(events, ev, now)
        return

    if RE_PPPOE_DOWN.search(line) and ("pppoe" in line.lower() or "wan" in line.lower() or "pado" in line.lower() or "modem hangup" in line.lower()):
        ev = {"ts": now, "cat": "pppoe", "type": "down", "msg": line[-160:]}
        pppoe_ev.append(ev)
        st["pppoe_events"] = pppoe_ev[-40:]
        bump(hourly, now, "pppoe")
        append_event(events, ev, now)
        st["redial_ts"].append(now)
        return
    if "Interface 'wan' is now up" in line or "CHAP authentication succeeded" in line:
        ev = {"ts": now, "cat": "pppoe", "type": "up", "msg": line[-160:]}
        pppoe_ev.append(ev)
        st["pppoe_events"] = pppoe_ev[-40:]
        append_event(events, ev, now)
        return

    m = RE_DHCPACK.search(line)
    if m:
        ip, mac, name = m.group(1), (m.group(2) or "").lower(), m.group(3) or "*"
        seen = st.setdefault("dhcp_seen", {})
        kind = "ack" if mac in seen else "new"
        seen[mac] = now
        ev = {"ts": now, "cat": "dhcp", "type": kind, "ip": ip, "mac": mac, "name": name}
        append_event(events, ev, now)
        return
    m = RE_DHCPNAK.search(line)
    if m:
        ev = {"ts": now, "cat": "dhcp", "type": "nak", "ip": m.group(1),
              "mac": (m.group(2) or "").lower(), "name": m.group(3) or ""}
        append_event(events, ev, now)
        return


def top_map(d, n=10):
    items = sorted(d.items(), key=lambda kv: kv[1], reverse=True)[:n]
    return [{"name": k, "count": v} for k, v in items]


def default_state():
    return {
        "cursor": "",
        "events": [],
        "hourly": {},
        "attack": {},
        "pppoe_events": [],
        "redial_ts": [],
        "dhcp_seen": {},
    }


def build_snapshot(st, now):
    wan = wan_status()
    blocked = (uci_get("statusmon.attack.block") or "").split()
    redials = [t for t in st["redial_ts"] if now - t <= 86400]
    hourly = prune_hourly(st["hourly"], now)
    st["hourly"] = hourly
    st["redial_ts"] = redials

    series = []
    for i in range(HOUR_KEEP):
        ts = (now // 3600 * 3600) - (HOUR_KEEP - 1 - i) * 3600
        row = hourly.get(str(ts), {})
        series.append({
            "ts": ts,
            "auth": int(row.get("auth") or 0),
            "pppoe": int(row.get("pppoe") or 0),
        })

    st["attack"] = {ip: row for ip, row in st["attack"].items() if is_real_attack(row, now)}
    if len(st["attack"]) > MAX_RECORDS:
        keep = sorted(st["attack"].items(), key=lambda kv: int(kv[1].get("last_ts") or 0), reverse=True)[:MAX_RECORDS]
        st["attack"] = dict(keep)

    attack_rows = []
    auth_dports, auth_sports = auth_ports_from_events(st["events"])
    for ip, row in st["attack"].items():
        if not is_real_attack(row, now):
            continue
        if int(row.get("auth_count") or 0) <= 0:
            continue
        ports = list(row.get("ports") or [])
        for p in (auth_dports.get(ip) or []):
            if p not in ports:
                ports.append(p)
        sports = list(row.get("sports") or [])
        for s in (auth_sports.get(ip) or []):
            if s not in sports:
                sports.append(s)
        attack_rows.append({
            "ip": ip,
            "count": row.get("count") or 0,
            "auth_count": row.get("auth_count") or 0,
            "ports": ports[:12],
            "sports": sports[:12],
            "first_ts": row.get("first_ts") or 0,
            "last_ts": row.get("last_ts") or 0,
            "blocked": ip in blocked,
        })
    attack_rows.sort(key=lambda r: r["last_ts"], reverse=True)

    last24 = now - 86400
    auth24 = sum(1 for e in st["events"] if e.get("type") == "auth" and e.get("ts", 0) >= last24)
    src24 = {e.get("ip") for e in st["events"] if e.get("type") == "auth" and e.get("ts", 0) >= last24 and e.get("ip")}

    return {
        "ts": now,
        "cards": {
            "attack_24h": auth24,
            "auth_24h": auth24,
            "sources_24h": len(src24),
            "pppoe_redial_24h": len(redials),
            "pppoe_online": 1 if wan["up"] else 0,
        },
        "series": series,
        "attack_summary": attack_rows[:MAX_RECORDS],
        "top_ip": sorted(attack_rows, key=lambda r: r["count"], reverse=True)[:10],
        "pppoe": {
            "up": wan["up"],
            "uptime": wan["uptime"],
            "ipv4": wan["ipv4"],
            "ipv6": wan["ipv6"],
            "device": wan["device"],
            "redials_24h": len(redials),
            "frequent": len(redials) >= 5,
            "events": st["pppoe_events"][-20:],
        },
        "blocked": blocked,
    }


def pull_lines(cursor):
    raw = sh(["logread", "-l", "2000"])
    lines = raw.splitlines()
    if not lines:
        return [], cursor
    if cursor and cursor in lines:
        i = len(lines) - 1 - lines[::-1].index(cursor)
        new = lines[i + 1:]
    else:
        new = lines
    return new, lines[-1]


def loop():
    os.makedirs(DIR, exist_ok=True)
    st = load_json(STATE, None) or default_state()
    for k, v in default_state().items():
        st.setdefault(k, v)
    load_persist(st)
    last = {}
    while True:
        now = int(time.time())
        nets = lan_nets()
        lines, st["cursor"] = pull_lines(st.get("cursor") or "")
        for line in lines:
            try:
                parse_line(line, st, now, nets)
            except Exception:
                continue
        handle_cmd(st)
        st["hourly"] = prune_hourly(st["hourly"], now)
        snap = build_snapshot(st, now)
        write_json(SNAP, snap)
        write_json(STATE, st)
        flush_persist(st, last)
        try:
            write_jsonl(EVENTS, log_events(st))
        except OSError:
            pass
        time.sleep(INTERVAL)


def selftest():
    nets = lan_nets()
    now = 1700000000
    st = default_state()
    parse_line("dropbear[1]: Bad password attempt for 'root' from 8.8.8.8:4242", st, now, nets)
    assert st["attack"]["8.8.8.8"]["auth_count"] == 1, st["attack"]
    assert st["attack"]["8.8.8.8"]["ports"] == [22], st["attack"]["8.8.8.8"]
    assert st["events"][-1]["port"] == 22
    assert st["events"][-1]["sport"] == 4242
    assert st["attack"]["8.8.8.8"]["sports"] == [4242]
    # 失败登录同时进入登录日志（cat=login, type=fail）
    sshfail = [e for e in st["events"] if e.get("svc") == "ssh" and e.get("type") == "fail"]
    assert sshfail and sshfail[-1].get("ip") == "8.8.8.8", sshfail
    parse_line("dropbear[1]: Bad password attempt for 'root' from 192.168.10.2:4242", st, now, nets)
    assert "192.168.10.2" not in st["attack"]
    lanfail = [e for e in st["events"] if e.get("svc") == "ssh" and e.get("ip") == "192.168.10.2"]
    assert lanfail, "LAN 失败登录也应进入登录日志"
    parse_line("luci: failed login on /cgi-bin/luci for root from 1.2.3.4", st, now, nets)
    assert st["attack"]["1.2.3.4"]["auth_count"] == 1
    assert st["attack"]["1.2.3.4"]["ports"] == [80]
    lucifail = [e for e in st["events"] if e.get("svc") == "luci" and e.get("type") == "fail"]
    assert lucifail and lucifail[-1].get("user") == "root", lucifail
    # 端口探测日志不再采集（nft log 规则已移除），不应产生记录
    parse_line("statusmon-attack: IN=pppoe-wan OUT= SRC=9.9.9.9 DST=10.0.0.1 PROTO=TCP SPT=1 DPT=3333", st, now, nets)
    assert "9.9.9.9" not in st["attack"]
    full = build_snapshot(st, now)
    shown = {r["ip"] for r in full["attack_summary"]}
    assert "8.8.8.8" in shown
    assert "1.2.3.4" in shown
    assert "9.9.9.9" not in shown
    by_ip = {r["ip"]: r for r in full["attack_summary"]}
    assert 22 in (by_ip["8.8.8.8"].get("ports") or [])
    assert 80 in (by_ip["1.2.3.4"].get("ports") or [])
    assert 4242 in (by_ip["8.8.8.8"].get("sports") or [])
    assert full["cards"]["pppoe_online"] in (0, 1)
    # 永久保留：远早于 7 天前的爆破记录仍应展示
    old = "7.7.7.7"
    st["attack"][old] = {"ip": old, "count": 1, "auth_count": 1, "ports": [22],
                         "sports": [], "first_ts": now - 40 * 86400, "last_ts": now - 40 * 86400,
                         "auth_ts": []}
    full2 = build_snapshot(st, now)
    assert old in {r["ip"] for r in full2["attack_summary"]}
    # 登录成功事件（SSH / LuCI）归入 login 类别，不计入攻击
    parse_line("dropbear[2]: Password auth succeeded for 'root' from 8.8.8.8:5555", st, now, nets)
    parse_line("dispatcher.uc: luci: accepted login on / for root from 1.2.3.4", st, now, nets)
    login = [e for e in log_events(st) if e.get("cat") == "login"]
    ok = [e for e in login if e.get("type") == "ok"]
    assert len(ok) == 2, ok
    assert {e.get("svc") for e in ok} == {"ssh", "luci"}
    assert {e.get("type") for e in login} == {"ok", "fail"}
    assert st["attack"]["8.8.8.8"]["auth_count"] == 1  # 成功登录不增加爆破计数
    # DHCP 事件（真实 dnsmasq 行在 tag 与事件名之间带数字事务 ID）
    parse_line("dnsmasq-dhcp[1]: 4239439749 DHCPACK(br-lan) 192.168.10.101 64:79:f0:d7:9a:e7 Desk", st, now, nets)
    parse_line("dnsmasq-dhcp[1]: 1505782091 DHCPNAK(br-lan) 192.168.10.101 64:79:f0:d7:9a:e7", st, now, nets)
    # 兼容旧格式（无事务 ID）
    parse_line("dnsmasq-dhcp[2]: DHCPACK(br-lan) 192.168.10.102 aa:bb:cc:dd:ee:ff Phone", st, now, nets)
    dhcp = [e for e in log_events(st) if e.get("cat") == "dhcp"]
    assert len(dhcp) == 3, dhcp
    assert dhcp[0].get("ip") == "192.168.10.101" and dhcp[0].get("mac") == "64:79:f0:d7:9a:e7"
    assert dhcp[1].get("type") == "nak" and dhcp[1].get("ip") == "192.168.10.101"
    assert dhcp[1].get("mac") == "64:79:f0:d7:9a:e7"
    assert dhcp[2].get("ip") == "192.168.10.102"
    # 各类别分类正确且互不混淆
    cats = {e.get("cat") for e in log_events(st)}
    assert {"attack", "login", "dhcp"} <= cats
    print("statusmon attack selftest ok")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        selftest()
    else:
        loop()
