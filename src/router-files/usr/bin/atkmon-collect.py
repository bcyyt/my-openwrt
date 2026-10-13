#!/usr/bin/env python3
# atkmon collector: parse syslog + wan/dhcp/iptv snapshots into /var/lib/atkmon

import ipaddress
import json
import os
import re
import subprocess
import time
import sys
from collections import defaultdict

DIR = "/var/lib/atkmon"
SNAP = DIR + "/snapshot.json"
STATE = DIR + "/state.json"
EVENTS = DIR + "/events.jsonl"
IPTV_STATUS = "/var/log/iptv-auth/status.json"
IPTV_CLIENTS = "/var/log/iptv-auth/clients.json"
LEASES = "/tmp/dhcp.leases"
WATCH_SEC = 300
NEIGH_UP = {"REACHABLE", "DELAY", "PROBE", "STALE"}
PROBE_WINDOW = 600
PROBE_HIT_MIN = 8
PROBE_PORT_MIN = 5
PROBE_UDP_MIN = 20

MAX_EVENTS = 20000
EVENT_TTL = 86400
HOUR_KEEP = 168
INTERVAL = 5

RE_DROPBEAR = re.compile(
    r"dropbear.*(?:Bad password attempt for '([^']*)'|Login attempt for nonexistent user).*from ([0-9a-fA-F:.]+)"
)
RE_LUCI = re.compile(r"luci: failed login(?: on \S+)?(?: for \S+)? from ([0-9a-fA-F:.]+)")
RE_ATKMON = re.compile(r"atkmon:.*SRC=(\S+).*PROTO=(\S+).*DPT=(\d+)")
RE_PPPOE_UP = re.compile(r"(pppoe-|Interface 'wan' is now up|CHAP authentication succeeded|PPP session is )")
RE_PPPOE_DOWN = re.compile(r"(Modem hangup|Connection terminated|Interface 'wan' is now down|Timeout waiting for PADO)")
RE_DNS_Q = re.compile(r"dnsmasq\[\d+\]: (?:\d+ \S+ )?query\[(\w+)\] (\S+) from (\S+)")
RE_DNS_NX = re.compile(r"dnsmasq\[\d+\]: .*\s(\S+) is NXDOMAIN")
RE_DHCPACK = re.compile(r"dnsmasq-dhcp\[\d+\]: DHCPACK\(\S+\) (\S+) (\S+)(?: (\S+))?")
RE_DHCPNAK = re.compile(r"dnsmasq-dhcp\[\d+\]: DHCPNAK")
RE_DHCPDIS = re.compile(r"dnsmasq-dhcp\[\d+\]: DHCPDISCOVER\(\S+\) (\S+)")
RE_IPTV_URL = re.compile(r"requested URL[: ]+(\S+)")
RE_IPTV_FAIL = re.compile(r"iptv-auth.*(fail|error|timeout|unreachable)", re.I)


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


def open_ports():
    raw = uci_get("atkmon.main.open_ports") or "22 80 443 2323 23232 2000 23234 554 16601"
    out = set()
    for p in raw.replace(",", " ").split():
        try:
            out.add(int(p))
        except ValueError:
            pass
    return out


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


def hour_key(ts):
    return str(int(ts) // 3600 * 3600)


def prune_hourly(hourly, now):
    cut = now - HOUR_KEEP * 3600
    return {k: v for k, v in hourly.items() if int(k) >= cut}


def append_event(events, ev, now):
    events.append(ev)
    cut = now - EVENT_TTL
    events[:] = [e for e in events if int(e.get("ts") or 0) >= cut][-MAX_EVENTS:]


def bump(hourly, ts, field, n=1):
    k = hour_key(ts)
    row = hourly.setdefault(k, {"auth": 0, "probe": 0, "pppoe": 0, "dns_nx": 0, "dhcp": 0, "iptv": 0})
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


def neigh_index():
    by_ip = {}
    by_mac = {}
    raw = sh(["ip", "neigh", "show"])
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        ip = parts[0]
        mac = ""
        if "lladdr" in parts:
            i = parts.index("lladdr")
            if i + 1 < len(parts):
                mac = parts[i + 1].lower()
        st = parts[-1]
        rec = {"ip": ip, "mac": mac, "state": st, "online": st in NEIGH_UP}
        by_ip[ip] = rec
        if mac:
            prev = by_mac.get(mac)
            if not prev or (not prev.get("online") and rec["online"]):
                by_mac[mac] = rec
    return by_ip, by_mac


def proc_alive(needle):
    needle = (needle or "").lower()
    if not needle:
        return False
    raw = sh(["ps", "w"]) or sh(["ps"])
    for line in raw.splitlines():
        if needle in line.lower():
            return True
    return False


def dhcp_leases():
    rows = []
    by_ip, by_mac = neigh_index()
    now = int(time.time())
    try:
        with open(LEASES, "r") as f:
            for line in f:
                p = line.split()
                if len(p) >= 4:
                    mac = p[1].lower()
                    ip = p[2]
                    name = p[3] if p[3] != "*" else ""
                    exp = int(p[0]) if p[0].isdigit() else 0
                    rec = by_ip.get(ip) or by_mac.get(mac) or {}
                    rows.append({
                        "mac": mac,
                        "ip": ip,
                        "name": name or "*",
                        "exp": exp,
                        "remain": max(0, exp - now) if exp else 0,
                        "online": bool(rec.get("online")),
                        "neigh": rec.get("state") or "",
                    })
    except OSError:
        pass
    rows.sort(key=lambda r: (not r.get("online"), (r.get("name") or "").lower(), r.get("ip") or ""))
    return rows


def iptv_snap():
    st = load_json(IPTV_STATUS, {})
    clients = load_json(IPTV_CLIENTS, {})
    live = 0
    catchup = 0
    recent = []
    now = time.time()
    auth_running = proc_alive("iptv-auth.py")
    r2h = proc_alive("rtp2httpd")
    auth_ok = bool(st.get("auth_ok") if "auth_ok" in st else st.get("ok"))
    if isinstance(clients, dict):
        items = []
        for ip, c in clients.items():
            if not isinstance(c, dict):
                continue
            try:
                last = float(c.get("last") or 0)
            except (TypeError, ValueError):
                last = 0
            items.append((ip, c, last))
        items.sort(key=lambda x: -x[2])
        for ip, c, last in items[:40]:
            ch = str(c.get("channel") or c.get("ch") or "")
            kind = "catchup" if "catchup" in ch.lower() or "playseek" in ch.lower() else "live"
            watching = last > 0 and (now - last) <= WATCH_SEC
            if watching:
                if kind == "catchup":
                    catchup += 1
                else:
                    live += 1
            recent.append({
                "ip": ip,
                "channel": ch,
                "kind": kind,
                "ua": str(c.get("ua") or "")[:80],
                "last": int(last),
                "watching": watching,
            })
    return {
        "auth_ok": auth_ok,
        "online": bool(auth_running and auth_ok),
        "auth_running": auth_running,
        "rtp2httpd": r2h,
        "last_run": str(st.get("last_run") or ""),
        "next_run": str(st.get("next_run") or ""),
        "channels": int(st.get("channels") or 0),
        "status": st,
        "live": live,
        "catchup": catchup,
        "clients": recent[:20],
    }


def is_real_attack(row, now=None):
    if int(row.get("auth_count") or 0) > 0:
        return True
    now = int(now or time.time())
    recent = [(int(t), p) for t, p in (row.get("probe_ports") or []) if now - int(t) <= PROBE_WINDOW]
    nports = len({p for t, p in recent if p})
    return nports >= PROBE_PORT_MIN or len(recent) >= PROBE_HIT_MIN


def note_probe(st, ip, dpt, proto, now):
    pending = st.setdefault("probe_pending", {})
    rec = pending.get(ip) or {"hits": [], "promoted": False}
    already = bool(rec.get("promoted"))
    rec["hits"] = [h for h in (rec.get("hits") or []) if now - h[0] <= PROBE_WINDOW]
    rec["hits"].append((now, dpt, proto))
    rec["hits"] = rec["hits"][-80:]
    hits = rec["hits"]
    nports = len({h[1] for h in hits if h[1]})
    tcp_n = sum(1 for h in hits if h[2] == "tcp")
    udp_n = sum(1 for h in hits if h[2] == "udp")
    should = nports >= PROBE_PORT_MIN or tcp_n >= PROBE_HIT_MIN or udp_n >= PROBE_UDP_MIN
    rec["promoted"] = already or should
    rec["last"] = now
    pending[ip] = rec
    if not rec["promoted"]:
        return None
    if already:
        return [(now, dpt, proto)]
    return list(hits)


def attack_tag(summary, ip, now):
    row = summary.get(ip) or {}
    auths = [t for t in row.get("auth_ts") or [] if now - t <= 600]
    ports = set()
    for t, p in row.get("probe_ports") or []:
        if now - t <= 300:
            ports.add(p)
    tag = "probe"
    if len(auths) >= 5:
        tag = "auth"
    if len(ports) >= 8:
        tag = "scan"
    row["tag"] = tag
    row["auth_ts"] = auths[-20:]
    row["probe_ports"] = [(t, p) for t, p in (row.get("probe_ports") or []) if now - t <= 3600][-40:]
    summary[ip] = row


def parse_line(line, st, now, nets, ports):
    events = st["events"]
    hourly = st["hourly"]
    summary = st["attack"]
    dns = st["dns"]
    pppoe_ev = st["pppoe_events"]
    dhcp_ev = st["dhcp_events"]
    iptv_ev = st["iptv_events"]

    m = RE_DROPBEAR.search(line)
    if m:
        ip = parse_ip(m.group(2))
        if ip and not is_lan(ip, nets):
            user = m.group(1) or ""
            ev = {"ts": now, "cat": "attack", "type": "auth", "svc": "ssh", "ip": ip, "user": user, "port": 2323}
            append_event(events, ev, now)
            bump(hourly, now, "auth")
            row = summary.setdefault(ip, {"ip": ip, "count": 0, "auth_count": 0, "probe_count": 0,
                                          "ports": [], "first_ts": now, "last_ts": now, "auth_ts": [], "probe_ports": []})
            row["count"] += 1
            row["auth_count"] += 1
            row["last_ts"] = now
            row["auth_ts"].append(now)
            attack_tag(summary, ip, now)
        return

    m = RE_LUCI.search(line)
    if m:
        ip = parse_ip(m.group(1))
        if ip and not is_lan(ip, nets):
            ev = {"ts": now, "cat": "attack", "type": "auth", "svc": "luci", "ip": ip, "port": 80}
            append_event(events, ev, now)
            bump(hourly, now, "auth")
            row = summary.setdefault(ip, {"ip": ip, "count": 0, "auth_count": 0, "probe_count": 0,
                                          "ports": [], "first_ts": now, "last_ts": now, "auth_ts": [], "probe_ports": []})
            row["count"] += 1
            row["auth_count"] += 1
            row["last_ts"] = now
            row["auth_ts"].append(now)
            attack_tag(summary, ip, now)
        return

    m = RE_ATKMON.search(line)
    if m:
        st["probe_seen"] = True
        ip = parse_ip(m.group(1))
        try:
            dpt = int(m.group(3))
        except ValueError:
            dpt = 0
        proto = (m.group(2) or "TCP").split()[0].lower()
        if ip and not is_lan(ip, nets) and dpt not in ports:
            flushed = note_probe(st, ip, dpt, proto, now)
            if not flushed:
                return
            row = summary.setdefault(ip, {"ip": ip, "count": 0, "auth_count": 0, "probe_count": 0,
                                          "ports": [], "first_ts": now, "last_ts": now, "auth_ts": [], "probe_ports": []})
            for ts, port, pr in flushed:
                ev = {"ts": ts, "cat": "attack", "type": "probe", "svc": "fw", "ip": ip, "port": port, "proto": pr}
                append_event(events, ev, now)
                bump(hourly, ts, "probe")
                row["count"] += 1
                row["probe_count"] += 1
                row["last_ts"] = ts
                if port and port not in row["ports"]:
                    row["ports"].append(port)
                row["probe_ports"].append((ts, port))
            attack_tag(summary, ip, now)
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

    m = RE_DNS_Q.search(line)
    if m:
        st["dns_available"] = True
        qtype, name, src = m.group(1), m.group(2).rstrip("."), m.group(3)
        dns["q"] += 1
        dns["top"][name] = dns["top"].get(name, 0) + 1
        dns["clients"][src] = dns["clients"].get(src, 0) + 1
        minute = str(now // 60)
        ck = src + "|" + minute
        dns["rate"][ck] = dns["rate"].get(ck, 0) + 1
        if dns["rate"][ck] >= 200 and src not in dns["hot"]:
            dns["hot"][src] = now
        return
    m = RE_DNS_NX.search(line)
    if m:
        st["dns_available"] = True
        name = m.group(1).rstrip(".")
        dns["nx"] += 1
        dns["nx_top"][name] = dns["nx_top"].get(name, 0) + 1
        bump(hourly, now, "dns_nx")
        return

    m = RE_DHCPACK.search(line)
    if m:
        ip, mac, name = m.group(1), m.group(2).lower(), m.group(3) or "*"
        seen = st["dhcp_seen"]
        kind = "ack"
        if mac not in seen:
            kind = "new"
            st["dhcp_new_ts"].append(now)
        seen[mac] = now
        ev = {"ts": now, "cat": "dhcp", "type": kind, "ip": ip, "mac": mac, "name": name}
        dhcp_ev.append(ev)
        st["dhcp_events"] = dhcp_ev[-40:]
        bump(hourly, now, "dhcp")
        append_event(events, ev, now)
        return
    if RE_DHCPNAK.search(line):
        ev = {"ts": now, "cat": "dhcp", "type": "nak", "msg": line[-120:]}
        dhcp_ev.append(ev)
        st["dhcp_events"] = dhcp_ev[-40:]
        append_event(events, ev, now)
        return
    m = RE_DHCPDIS.search(line)
    if m:
        return

    m = RE_IPTV_URL.search(line)
    if m:
        url = m.group(1)
        if "/status" in url or "/assets/" in url or "playlist.m3u" in url:
            return
        kind = "catchup" if "catchup" in url or "playseek" in url else "live"
        path = url.split("?")[0]
        parts = [p for p in path.split("/") if p]
        ch = ""
        if "catchup" in parts:
            i = parts.index("catchup")
            ch = parts[i - 1] if i > 0 else ""
        elif parts:
            ch = parts[-1]
        try:
            from urllib.parse import unquote
            ch = unquote(ch)
        except Exception:
            pass
        ev = {"ts": now, "cat": "iptv", "type": kind, "channel": ch, "url": url[:180]}
        iptv_ev.append(ev)
        st["iptv_events"] = iptv_ev[-40:]
        bump(hourly, now, "iptv")
        append_event(events, ev, now)
        return
    if RE_IPTV_FAIL.search(line):
        ev = {"ts": now, "cat": "iptv", "type": "fail", "msg": line[-160:]}
        iptv_ev.append(ev)
        st["iptv_events"] = iptv_ev[-40:]
        append_event(events, ev, now)


def top_map(d, n=10):
    items = sorted(d.items(), key=lambda kv: kv[1], reverse=True)[:n]
    return [{"name": k, "count": v} for k, v in items]


def default_state():
    return {
        "cursor": "",
        "events": [],
        "hourly": {},
        "attack": {},
        "probe_seen": False,
        "dns_available": False,
        "dns": {"q": 0, "nx": 0, "top": {}, "nx_top": {}, "clients": {}, "rate": {}, "hot": {}},
        "pppoe_events": [],
        "redial_ts": [],
        "dhcp_events": [],
        "dhcp_seen": {},
        "dhcp_new_ts": [],
        "iptv_events": [],
        "dns_reset": 0,
        "probe_pending": {},
    }


def reset_dns_daily(st, now):
    if now - int(st.get("dns_reset") or 0) > 86400:
        st["dns"] = {"q": 0, "nx": 0, "top": {}, "nx_top": {}, "clients": {}, "rate": {}, "hot": {}}
        st["dns_reset"] = now


def build_snapshot(st, now):
    wan = wan_status()
    leases = dhcp_leases()
    iptv = iptv_snap()
    blocked = (uci_get("atkmon.main.block") or "").split()
    redials = [t for t in st["redial_ts"] if now - t <= 86400]
    new_dev = [t for t in st["dhcp_new_ts"] if now - t <= 86400]
    hourly = prune_hourly(st["hourly"], now)
    st["hourly"] = hourly
    st["redial_ts"] = redials
    st["dhcp_new_ts"] = new_dev

    series = []
    for i in range(HOUR_KEEP):
        ts = (now // 3600 * 3600) - (HOUR_KEEP - 1 - i) * 3600
        row = hourly.get(str(ts), {})
        series.append({
            "ts": ts,
            "auth": int(row.get("auth") or 0),
            "probe": int(row.get("probe") or 0),
            "pppoe": int(row.get("pppoe") or 0),
            "dns_nx": int(row.get("dns_nx") or 0),
            "dhcp": int(row.get("dhcp") or 0),
            "iptv": int(row.get("iptv") or 0),
        })

    pending = st.get("probe_pending") or {}
    keep_p = {}
    for ip, rec in pending.items():
        hits = [h for h in (rec.get("hits") or []) if now - h[0] <= PROBE_WINDOW]
        last = int(rec.get("last") or (hits[-1][0] if hits else 0))
        if rec.get("promoted") and now - last <= 86400:
            rec["hits"] = hits
            keep_p[ip] = rec
        elif hits:
            rec["hits"] = hits
            keep_p[ip] = rec
    st["probe_pending"] = keep_p
    st["attack"] = {ip: row for ip, row in st["attack"].items() if is_real_attack(row, now)}
    real_ips = set(st["attack"])
    st["events"] = [e for e in st["events"] if e.get("type") != "probe" or e.get("ip") in real_ips]

    attack_rows = []
    for ip, row in st["attack"].items():
        if now - int(row.get("last_ts") or 0) > 7 * 86400:
            continue
        if not is_real_attack(row, now):
            continue
        if int(row.get("auth_count") or 0) <= 0:
            continue
        attack_rows.append({
            "ip": ip,
            "tag": row.get("tag") or "probe",
            "count": row.get("count") or 0,
            "auth_count": row.get("auth_count") or 0,
            "probe_count": row.get("probe_count") or 0,
            "ports": (row.get("ports") or [])[:12],
            "first_ts": row.get("first_ts") or 0,
            "last_ts": row.get("last_ts") or 0,
            "blocked": ip in blocked,
        })
    attack_rows.sort(key=lambda r: r["last_ts"], reverse=True)

    last24 = now - 86400
    auth24 = sum(1 for e in st["events"] if e.get("type") == "auth" and e.get("ts", 0) >= last24)
    probe24 = sum(1 for e in st["events"] if e.get("type") == "probe" and e.get("ts", 0) >= last24)
    src24 = {e.get("ip") for e in st["events"] if e.get("type") == "auth" and e.get("ts", 0) >= last24 and e.get("ip")}

    dns = st["dns"]
    hot = [{"ip": k, "ts": v} for k, v in dns.get("hot", {}).items()]

    return {
        "ts": now,
        "probe_available": bool(st.get("probe_seen")),
        "dns_available": bool(st.get("dns_available")),
        "cards": {
            "attack_24h": auth24,
            "auth_24h": auth24,
            "probe_24h": probe24,
            "sources_24h": len(src24),
            "pppoe_redial_24h": len(redials),
            "pppoe_online": 1 if wan["up"] else 0,
            "dns_nx_24h": int(dns.get("nx") or 0),
            "dns_q_24h": int(dns.get("q") or 0),
            "dhcp_new_24h": len(new_dev),
            "dhcp_online": sum(1 for x in leases if x.get("online")),
            "iptv_live": iptv.get("live") or 0,
            "iptv_catchup": iptv.get("catchup") or 0,
            "iptv_online": 1 if iptv.get("online") else 0,
        },
        "series": series,
        "attack_summary": attack_rows[:80],
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
        "dns": {
            "available": bool(st.get("dns_available")),
            "queries": int(dns.get("q") or 0),
            "nxdomain": int(dns.get("nx") or 0),
            "top": top_map(dns.get("top") or {}),
            "nx_top": top_map(dns.get("nx_top") or {}),
            "hot_clients": hot[:10],
        },
        "iptv": {
            "auth_ok": iptv.get("auth_ok"),
            "online": bool(iptv.get("online")),
            "auth_running": bool(iptv.get("auth_running")),
            "rtp2httpd": bool(iptv.get("rtp2httpd")),
            "last_run": iptv.get("last_run") or "",
            "next_run": iptv.get("next_run") or "",
            "channels": int(iptv.get("channels") or 0),
            "live": iptv.get("live") or 0,
            "catchup": iptv.get("catchup") or 0,
            "clients": iptv.get("clients") or [],
            "events": st["iptv_events"][-20:],
            "running": bool(iptv.get("auth_running")),
        },
        "dhcp": {
            "leases": len(leases),
            "online": sum(1 for x in leases if x.get("online")),
            "new_24h": len(new_dev),
            "list": leases[:200],
            "events": st["dhcp_events"][-20:],
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
    while True:
        now = int(time.time())
        nets = lan_nets()
        ports = open_ports()
        reset_dns_daily(st, now)
        lines, st["cursor"] = pull_lines(st.get("cursor") or "")
        for line in lines:
            try:
                parse_line(line, st, now, nets, ports)
            except Exception:
                continue
        st["hourly"] = prune_hourly(st["hourly"], now)
        snap = build_snapshot(st, now)
        write_json(SNAP, snap)
        write_json(STATE, st)
        try:
            with open(EVENTS, "w") as f:
                for e in st["events"][-MAX_EVENTS:]:
                    f.write(json.dumps(e, ensure_ascii=False) + "\n")
        except OSError:
            pass
        time.sleep(INTERVAL)


def selftest():
    nets = lan_nets()
    ports = {22, 80, 443}
    now = 1700000000
    st = default_state()
    parse_line("dropbear[1]: Bad password attempt for 'root' from 8.8.8.8:4242", st, now, nets, ports)
    assert st["attack"]["8.8.8.8"]["auth_count"] == 1, st["attack"]
    parse_line("dropbear[1]: Bad password attempt for 'root' from 192.168.10.2:4242", st, now, nets, ports)
    assert "192.168.10.2" not in st["attack"]
    parse_line("luci: failed login on /cgi-bin/luci from 1.2.3.4", st, now, nets, ports)
    assert st["attack"]["1.2.3.4"]["auth_count"] == 1
    parse_line("atkmon: IN=pppoe-wan OUT= SRC=9.9.9.9 DST=10.0.0.1 PROTO=TCP SPT=1 DPT=3333", st, now, nets, ports)
    assert "9.9.9.9" not in st["attack"]
    parse_line("atkmon: IN=pppoe-wan OUT= SRC=9.9.9.9 DST=10.0.0.1 PROTO=TCP SPT=1 DPT=22", st, now, nets, ports)
    assert "9.9.9.9" not in st["attack"]
    for port in (2001, 2002, 2003, 2004, 2005, 2006, 2007, 2008):
        parse_line("atkmon: IN=pppoe-wan OUT= SRC=9.9.9.9 DST=10.0.0.1 PROTO=TCP SPT=1 DPT=%d" % port, st, now, nets, ports)
    assert st["attack"]["9.9.9.9"]["probe_count"] >= 8
    assert len(st["attack"]["9.9.9.9"]["ports"]) >= 5
    parse_line("dnsmasq[1]: query[A] example.com from 192.168.10.20", st, now, nets, ports)
    assert st["dns"]["q"] == 1 and st["dns_available"]
    parse_line("dnsmasq[1]: 11 192.168.10.124/3316 query[A] hicloud.com from 192.168.10.124", st, now, nets, ports)
    assert st["dns"]["q"] == 2
    parse_line("dnsmasq[1]: config example.invalid is NXDOMAIN", st, now, nets, ports)
    assert st["dns"]["nx"] == 1
    parse_line("dnsmasq[1]: 8 192.168.10.100/65358 reply nosuch.invalid is NXDOMAIN", st, now, nets, ports)
    assert st["dns"]["nx"] == 2
    parse_line("dnsmasq-dhcp[1]: DHCPACK(br-lan) 192.168.10.50 aa:bb:cc:dd:ee:ff phone", st, now, nets, ports)
    assert st["dhcp_events"][-1]["type"] == "new"
    parse_line("rtp2httpd requested URL: /湖南卫视/catchup?playseek=1", st, now, nets, ports)
    assert st["iptv_events"][-1]["type"] == "catchup"
    snap = iptv_snap()
    assert "online" in snap and "auth_running" in snap
    assert "channels" in snap
    drows = dhcp_leases()
    assert isinstance(drows, list)
    full = build_snapshot(st, now)
    shown = {r["ip"] for r in full["attack_summary"]}
    assert "8.8.8.8" in shown
    assert "1.2.3.4" in shown
    assert "9.9.9.9" not in shown
    assert full["cards"]["pppoe_online"] in (0, 1)
    print("atkmon selftest ok")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        selftest()
    else:
        loop()
