"""Box controller: live metrics history, disks, Docker, processes, systemd units
and logs, network/WireGuard, cron, quick actions and a one-call overview with
alerts.

Design rules (the box is often under heavy load, load avg 20-40 observed):
  * Nothing here blocks a request on a slow daemon. Docker state is served from
    a single-flight background cache; a request only kicks a refresh.
  * Every subprocess has a hard timeout and every payload is bounded.
  * Metrics come from /proc (no subprocess) on a 5 s sampler thread.
"""
import json
import os
import re
import signal
import subprocess
import threading
import time
from collections import deque
from pathlib import Path

from . import box

HELM_DIR = Path.home() / ".helm"
ACTIONS_FILE = HELM_DIR / "actions.json"

_NAME_RE = re.compile(r"^[A-Za-z0-9@._:\-]+$")


def _run(cmd, timeout=10):
    """subprocess with a hard deadline that never blocks past it.

    subprocess.run(timeout=) kills and then *waits* for the child; a child stuck
    in D-state on a wedged FUSE mount never dies, so that wait hangs forever.
    Here the child is killed and abandoned (a reaper thread collects it later).
    """
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, errors="replace",
                             start_new_session=True)
    except Exception as e:  # noqa: BLE001
        return -1, "", str(e)
    result = {}

    def comm():
        result["out"], result["err"] = p.communicate()
    t = threading.Thread(target=comm, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:  # noqa: BLE001
            pass
        t.join(2)
        return -1, result.get("out", "") or "", f"timed out after {timeout}s"
    return p.returncode, result.get("out", ""), result.get("err", "")


# ================================================================ metrics

SAMPLE_EVERY = 5          # seconds
HISTORY = 720             # 1 hour at 5 s

_hist = deque(maxlen=HISTORY)
_hist_lock = threading.Lock()
_prev = {}


def _cpu_times():
    with open("/proc/stat") as f:
        parts = f.readline().split()[1:]
    vals = list(map(int, parts))
    idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
    return sum(vals), idle


def _net_bytes():
    rx = tx = 0
    with open("/proc/net/dev") as f:
        for line in f.readlines()[2:]:
            name, _, rest = line.partition(":")
            name = name.strip()
            if name == "lo" or name.startswith(("veth", "docker", "br-")):
                continue
            cols = rest.split()
            rx += int(cols[0])
            tx += int(cols[8])
    return rx, tx


def _disk_io():
    rd = wr = 0
    with open("/proc/diskstats") as f:
        for line in f:
            c = line.split()
            if len(c) < 10 or not re.match(r"^(sd[a-z]+|vd[a-z]+|nvme\d+n\d+|xvd[a-z]+)$", c[2]):
                continue
            rd += int(c[5]) * 512
            wr += int(c[9]) * 512
    return rd, wr


def _meminfo():
    mem = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, v = line.partition(":")
            mem[k.strip()] = int(v.split()[0])
    return mem


def sample():
    now = time.time()
    total, idle = _cpu_times()
    rx, tx = _net_bytes()
    rd, wr = _disk_io()
    mem = _meminfo()
    point = {"t": round(now, 1)}
    p = _prev
    if p:
        dt = max(now - p["t"], 0.001)
        dtot = total - p["total"]
        point["cpu"] = round(100 * (1 - (idle - p["idle"]) / dtot), 1) if dtot > 0 else 0.0
        point["rx"] = max(0, int((rx - p["rx"]) / dt))
        point["tx"] = max(0, int((tx - p["tx"]) / dt))
        point["rd"] = max(0, int((rd - p["rd"]) / dt))
        point["wr"] = max(0, int((wr - p["wr"]) / dt))
    mt = mem.get("MemTotal", 1)
    point["mem"] = round(100 * (mt - mem.get("MemAvailable", 0)) / mt, 1)
    st = mem.get("SwapTotal", 0)
    point["swap"] = round(100 * (st - mem.get("SwapFree", 0)) / st, 1) if st else 0.0
    point["load"] = round(os.getloadavg()[0], 2)
    _prev.update(t=now, total=total, idle=idle, rx=rx, tx=tx, rd=rd, wr=wr)
    if "cpu" in point:
        with _hist_lock:
            _hist.append(point)
    return point


def _sampler():
    while True:
        try:
            sample()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(SAMPLE_EVERY)


def metrics(minutes: int = 60, max_points: int = 180) -> dict:
    minutes = max(1, min(minutes, 60))
    cutoff = time.time() - minutes * 60
    with _hist_lock:
        pts = [p for p in _hist if p["t"] >= cutoff]
    if len(pts) > max_points:
        step = len(pts) / max_points
        # keep the max of each bucket for spiky series so peaks survive
        out = []
        for i in range(max_points):
            b = pts[int(i * step):int((i + 1) * step)] or [pts[-1]]
            agg = {"t": b[-1]["t"]}
            for k in ("cpu", "mem", "swap", "load", "rx", "tx", "rd", "wr"):
                agg[k] = max(x.get(k, 0) for x in b)
            out.append(agg)
        pts = out
    return {"interval": SAMPLE_EVERY, "minutes": minutes, "points": pts,
            "latest": pts[-1] if pts else None}


# ================================================================ disks

_REAL_FS = {"ext4", "ext3", "xfs", "btrfs", "zfs", "vfat", "fuse.rclone", "fuse.mergerfs", "nfs", "nfs4"}
_inflight = {}  # mount -> thread still blocked in statvfs (never spawn a second)


def _statvfs(mnt, timeout):
    prev = _inflight.get(mnt)
    if prev is not None and prev.is_alive():
        return None, "not responding"
    res = {}

    def go():
        try:
            res["st"] = os.statvfs(mnt)
        except OSError as e:
            res["err"] = str(e)
    t = threading.Thread(target=go, daemon=True)
    t.start()
    t.join(timeout)
    if t.is_alive():
        _inflight[mnt] = t
        return None, "not responding"
    _inflight.pop(mnt, None)
    return res.get("st"), res.get("err")


def disks() -> list:
    """Every real mount, via statvfs in an abandonable thread.

    No `df`: on a wedged rclone mount it sits in D-state and cannot be killed.
    A mount whose earlier statvfs is still blocked is reported without retrying.
    """
    res, seen = [], set()
    try:
        mounts = open("/proc/mounts").read().splitlines()
    except OSError:
        mounts = []
    for line in mounts:
        c = line.split()
        if len(c) < 3 or c[2] not in _REAL_FS:
            continue
        mnt = c[1].replace("\\040", " ")
        if mnt.startswith(("/boot", "/snap", "/var/lib/docker")) or mnt in seen:
            continue
        seen.add(mnt)
        remote = c[2].startswith(("fuse", "nfs"))
        item = {"mount": mnt, "fs": c[0], "type": c[2], "remote": remote,
                "total_gb": 0, "used_gb": 0, "free_gb": 0, "used_pct": 0, "ok": True}
        st, err = _statvfs(mnt, 3 if remote else 2)
        if st is None:
            item.update(ok=False, error=err or "error")
        else:
            total = st.f_blocks * st.f_frsize
            avail = st.f_bavail * st.f_frsize
            used = total - st.f_bfree * st.f_frsize
            item.update(total_gb=round(total / 1e9, 1), used_gb=round(used / 1e9, 1),
                        free_gb=round(avail / 1e9, 1),
                        used_pct=round(100 * used / (used + avail)) if used + avail else 0)
        res.append(item)
    return res


# ================================================================ docker

_dk = {"containers": [], "stats": {}, "ps_at": 0.0, "stats_at": 0.0, "error": None}
_dk_lock = threading.Lock()
_dk_busy = {"ps": False, "stats": False}


def _docker_ps():
    rc, out, err = _run(["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout=120)
    if rc != 0:
        with _dk_lock:
            _dk["error"] = (err or "docker ps failed").strip()[:300]
        return
    items = []
    for line in out.splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        labels = j.get("Labels") or ""
        project = ""
        m = re.search(r"com\.docker\.compose\.project=([^,]+)", labels)
        if m:
            project = m.group(1)
        status = j.get("Status", "")
        health = ""
        hm = re.search(r"\((healthy|unhealthy|health: starting)\)", status)
        if hm:
            health = hm.group(1).replace("health: ", "")
        items.append({
            "id": j.get("ID", "")[:12], "name": j.get("Names", ""), "image": j.get("Image", ""),
            "state": j.get("State", ""), "status": status, "health": health,
            "project": project, "ports": (j.get("Ports") or "")[:200],
            "created": j.get("CreatedAt", ""),
        })
    items.sort(key=lambda c: (c["state"] != "running", c["project"], c["name"]))
    with _dk_lock:
        _dk["containers"] = items
        _dk["ps_at"] = time.time()
        _dk["error"] = None


def _pct(s):
    try:
        return float(str(s).strip().rstrip("%"))
    except ValueError:
        return 0.0


def _docker_stats():
    rc, out, _ = _run(["docker", "stats", "--no-stream", "--format", "{{json .}}"], timeout=90)
    if rc != 0:
        return
    stats = {}
    for line in out.splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        stats[j.get("Name", "")] = {"cpu": _pct(j.get("CPUPerc")), "mem_pct": _pct(j.get("MemPerc")),
                                     "mem": j.get("MemUsage", "").split("/")[0].strip()}
    with _dk_lock:
        _dk["stats"] = stats
        _dk["stats_at"] = time.time()


def _kick(kind, fn):
    with _dk_lock:
        if _dk_busy[kind]:
            return
        _dk_busy[kind] = True

    def run():
        try:
            fn()
        finally:
            with _dk_lock:
                _dk_busy[kind] = False
    threading.Thread(target=run, daemon=True).start()


def docker_list(with_stats: bool = False, wait: float = 15.0) -> dict:
    now = time.time()
    if now - _dk["ps_at"] > 15:
        _kick("ps", _docker_ps)
    if with_stats and now - _dk["stats_at"] > 45:
        _kick("stats", _docker_stats)
    # Cold cache: wait (bounded) for the first listing rather than return empty.
    deadline = now + wait
    while not _dk["ps_at"] and _dk["error"] is None and time.time() < deadline:
        time.sleep(0.25)
    with _dk_lock:
        items = [dict(c, **_dk["stats"].get(c["name"], {})) for c in _dk["containers"]]
        return {"containers": items,
                "age_s": round(time.time() - _dk["ps_at"], 1) if _dk["ps_at"] else None,
                "stats_age_s": round(time.time() - _dk["stats_at"], 1) if _dk["stats_at"] else None,
                "refreshing": _dk_busy["ps"] or _dk_busy["stats"],
                "error": _dk["error"]}


DOCKER_ACTIONS = {"start", "stop", "restart", "pause", "unpause", "kill"}


def docker_action(name: str, action: str) -> dict:
    if not _NAME_RE.match(name) or action not in DOCKER_ACTIONS:
        return {"ok": False, "error": "bad container or action"}
    rc, out, err = _run(["docker", action, name], timeout=90)
    _kick("ps", _docker_ps)
    msg = (err or out).strip()[:500]
    return {"ok": rc == 0, "error": msg if rc else None, "output": msg}


def docker_logs(name: str, lines: int = 200) -> dict:
    if not _NAME_RE.match(name):
        return {"ok": False, "output": "bad container name"}
    lines = max(10, min(lines, 2000))
    rc, out, err = _run(["docker", "logs", "--tail", str(lines), "--timestamps", name], timeout=30)
    text = (out + ("\n" + err if err else "")).strip()
    return {"ok": rc == 0, "output": text[-30000:]}


# ================================================================ processes

def processes(sort: str = "cpu", limit: int = 60, q: str = "") -> list:
    key = {"cpu": "-pcpu", "mem": "-rss", "time": "-etimes"}.get(sort, "-pcpu")
    rc, out, _ = _run(["ps", "-eo", "pid=,ppid=,user=,pcpu=,pmem=,rss=,etimes=,stat=,comm=,args=",
                       f"--sort={key}"], timeout=10)
    procs = []
    me = os.getpid()
    ql = q.lower().strip()
    for line in out.splitlines():
        c = line.split(None, 9)
        if len(c) < 9:
            continue
        pid = int(c[0])
        if (pid == me or int(c[1]) == me) and not ql:
            continue  # helmd and the ps it just spawned
        args = c[9] if len(c) > 9 else c[8]
        if ql and ql not in args.lower() and ql not in c[8].lower():
            continue
        procs.append({"pid": pid, "ppid": int(c[1]), "user": c[2], "cpu": float(c[3]),
                      "mem": float(c[4]), "rss_mb": round(int(c[5]) / 1024, 1),
                      "elapsed": int(c[6]), "stat": c[7], "comm": c[8], "args": args[:400]})
        if len(procs) >= max(1, min(limit, 300)):
            break
    return procs


SIGNALS = {"TERM": signal.SIGTERM, "KILL": signal.SIGKILL, "HUP": signal.SIGHUP,
           "INT": signal.SIGINT, "STOP": signal.SIGSTOP, "CONT": signal.SIGCONT}


def signal_process(pid: int, sig: str) -> dict:
    if sig not in SIGNALS:
        return {"ok": False, "error": "bad signal"}
    if pid <= 1 or pid in (os.getpid(), os.getppid()):
        return {"ok": False, "error": "refusing to signal init or helmd itself"}
    try:
        os.kill(pid, SIGNALS[sig])
        return {"ok": True}
    except ProcessLookupError:
        return {"ok": False, "error": "no such process"}
    except PermissionError:
        return {"ok": False, "error": "permission denied"}


# ================================================================ systemd

def units(q: str = "", state: str = "") -> list:
    rc, out, _ = _run(["systemctl", "list-units", "--type=service", "--all", "--no-legend",
                       "--plain", "--no-pager"], timeout=15)
    watched = set(box.WATCHED_SERVICES)
    res = []
    ql = q.lower().strip()
    for line in out.splitlines():
        c = line.split(None, 4)
        if len(c) < 4:
            continue
        name = c[0].removesuffix(".service")
        item = {"name": name, "load": c[1], "active": c[2], "sub": c[3],
                "description": c[4] if len(c) > 4 else "", "watched": name in watched}
        if ql and ql not in name.lower() and ql not in item["description"].lower():
            continue
        if state and item["active"] != state:
            continue
        if item["load"] == "not-found" and not ql:
            continue
        res.append(item)
    order = {"failed": 0, "activating": 1, "active": 2, "deactivating": 3, "inactive": 4}
    res.sort(key=lambda u: (u["active"] != "failed", not u["watched"], order.get(u["active"], 5), u["name"]))
    return res[:400]


def unit_logs(name: str, lines: int = 200, priority: str = "") -> dict:
    if not _NAME_RE.match(name):
        return {"ok": False, "output": "bad unit name"}
    cmd = ["journalctl", "-u", name, "-n", str(max(10, min(lines, 2000))), "--no-pager",
           "-o", "short-iso"]
    if priority in ("err", "warning"):
        cmd += ["-p", priority]
    rc, out, err = _run(cmd, timeout=20)
    return {"ok": rc == 0, "output": (out or err).strip()[-30000:]}


def journal_errors(minutes: int = 60, lines: int = 200) -> dict:
    rc, out, err = _run(["journalctl", "-p", "err", "--since", f"-{max(1, min(minutes, 1440))}min",
                         "-n", str(lines), "--no-pager", "-o", "short-iso"], timeout=20)
    return {"ok": rc == 0, "output": (out or err).strip()[-30000:]}


# ================================================================ network

def network() -> dict:
    peers = []
    rc, out, _ = _run(["wg", "show", "all", "dump"], timeout=5)
    now = time.time()
    for line in out.splitlines():
        c = line.split("\t")
        if len(c) == 9:  # peer line: iface pub psk endpoint allowed handshake rx tx keepalive
            hs = int(c[5]) if c[5].isdigit() else 0
            peers.append({"iface": c[0], "key": c[1][:8], "endpoint": c[3] if c[3] != "(none)" else "",
                          "allowed": c[4], "handshake_ago": int(now - hs) if hs else None,
                          "rx": int(c[6]), "tx": int(c[7]),
                          "online": bool(hs) and now - hs < 180})
    rc, out, _ = _run(["ss", "-Htlnp"], timeout=5)
    ports = []
    for line in out.splitlines():
        c = line.split()
        if len(c) < 5:
            continue
        local = c[3]
        proc = ""
        m = re.search(r'users:\(\("([^"]+)"', line)
        if m:
            proc = m.group(1)
        addr, _, port = local.rpartition(":")
        ports.append({"addr": addr.strip("[]"), "port": int(port) if port.isdigit() else 0, "proc": proc})
    uniq = {}
    for p in ports:
        k = (p["port"], p["proc"])
        if k not in uniq:
            uniq[k] = p
        elif p["addr"] in ("0.0.0.0", "*", "::"):
            uniq[k] = p
    ports = sorted(uniq.values(), key=lambda p: p["port"])
    rc, ip, _ = _run(["ip", "-4", "-o", "addr", "show"], timeout=5)
    ifaces = []
    for line in ip.splitlines():
        c = line.split()
        if len(c) >= 4 and c[1] != "lo" and not c[1].startswith(("veth", "br-", "docker")):
            ifaces.append({"name": c[1], "addr": c[3]})
    return {"peers": peers, "ports": ports[:200], "interfaces": ifaces}


# ================================================================ cron

def cron() -> list:
    rc, out, _ = _run(["crontab", "-l"], timeout=5)
    jobs = []
    for i, raw in enumerate(out.splitlines()):
        line = raw.strip()
        if not line:
            continue
        enabled = not line.startswith("#")
        body = line.lstrip("#").strip()
        m = re.match(r"^(@\w+|(?:\S+\s+){4}\S+)\s+(.+)$", body)
        if not m:
            continue
        sched = m.group(1)
        if not enabled and not re.match(r"^(@(reboot|hourly|daily|weekly|monthly|yearly)|[\d*/,\-]+(\s+[\d*/,\-A-Za-z]+){4})$", sched):
            continue  # an ordinary comment, not a disabled job
        jobs.append({"line": i, "enabled": enabled, "schedule": sched, "command": m.group(2)[:500]})
    return jobs


# ================================================================ actions

DEFAULT_ACTIONS = [
    {"id": "health", "title": "Health report", "icon": "stethoscope", "confirm": False,
     "cmd": "uptime; echo; free -h; echo; df -h / /media 2>/dev/null; echo; systemctl --failed --no-legend --plain | head -20"},
    {"id": "failed", "title": "Failed units", "icon": "exclamationmark.octagon", "confirm": False,
     "cmd": "systemctl --failed --no-pager"},
    {"id": "disk-hogs", "title": "Root disk hogs", "icon": "internaldrive", "confirm": False,
     "cmd": "du -xh --max-depth=2 / 2>/dev/null | sort -rh | head -25", "timeout": 180},
    {"id": "mem-hogs", "title": "Memory hogs", "icon": "memorychip", "confirm": False,
     "cmd": "ps -eo pid,rss,comm --sort=-rss | head -20 | awk 'NR==1{print;next}{printf \"%-8s %7.0f MB  %s\\n\",$1,$2/1024,$3}'"},
    {"id": "docker-unhealthy", "title": "Restart unhealthy containers", "icon": "cross.case", "confirm": True,
     "cmd": "ids=$(docker ps -q --filter health=unhealthy); [ -z \"$ids\" ] && echo 'none unhealthy' || docker restart $ids",
     "timeout": 300},
    {"id": "drop-caches", "title": "Drop page cache", "icon": "wind", "confirm": True,
     "cmd": "sync; echo 1 > /proc/sys/vm/drop_caches; free -h"},
    {"id": "journal-vacuum", "title": "Vacuum journal to 500M", "icon": "trash", "confirm": True,
     "cmd": "journalctl --vacuum-size=500M 2>&1 | tail -3"},
    {"id": "wg", "title": "WireGuard status", "icon": "lock.shield", "confirm": False, "cmd": "wg show"},
]


def actions() -> list:
    try:
        data = json.loads(ACTIONS_FILE.read_text())
        if isinstance(data, list):
            return data
    except FileNotFoundError:
        HELM_DIR.mkdir(parents=True, exist_ok=True)
        ACTIONS_FILE.write_text(json.dumps(DEFAULT_ACTIONS, indent=2))
    except ValueError:
        pass
    return list(DEFAULT_ACTIONS)


def save_actions(items: list) -> list:
    clean = []
    for a in items:
        if not isinstance(a, dict) or not a.get("cmd") or not a.get("title"):
            continue
        aid = re.sub(r"[^a-z0-9\-]", "-", str(a.get("id") or a["title"]).lower())[:40] or f"a{len(clean)}"
        clean.append({"id": aid, "title": str(a["title"])[:60], "icon": str(a.get("icon") or "bolt")[:40],
                      "cmd": str(a["cmd"])[:4000], "confirm": bool(a.get("confirm")),
                      "timeout": int(a.get("timeout") or 120)})
    HELM_DIR.mkdir(parents=True, exist_ok=True)
    tmp = ACTIONS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(clean, indent=2))
    tmp.replace(ACTIONS_FILE)
    return clean


def run_action(aid: str) -> dict:
    for a in actions():
        if a.get("id") == aid:
            t0 = time.time()
            r = box.run_shell(a["cmd"], timeout=int(a.get("timeout") or 120))
            r["duration"] = round(time.time() - t0, 2)
            return r
    return {"ok": False, "exit": -1, "output": f"no action {aid!r}"}


# ================================================================ overview

def overview() -> dict:
    sysd = box.system_status()
    dk = docker_list(wait=0)
    ds = disks()
    rc, failed_out, _ = _run(["systemctl", "--failed", "--no-legend", "--plain", "--type=service"], timeout=8)
    failed = [l.split()[0].removesuffix(".service") for l in failed_out.splitlines() if l.strip()]
    net = network()
    tmux = box.tmux_sessions()
    latest = metrics(minutes=1)["latest"] or {}

    alerts = []
    for d in ds:
        if not d.get("ok", True):
            alerts.append({"level": "crit", "kind": "disk", "title": f"{d['mount']} not responding",
                           "detail": f"{d['type']} mount hung"})
        elif d["used_pct"] >= 90:
            alerts.append({"level": "crit" if d["used_pct"] >= 95 else "warn", "kind": "disk",
                           "title": f"{d['mount']} {d['used_pct']}% full", "detail": f"{d['free_gb']} GB free"})
    mp = 100 * sysd.get("mem_used_mb", 0) / max(sysd.get("mem_total_mb", 1), 1)
    if mp >= 90:
        alerts.append({"level": "warn", "kind": "memory", "title": f"Memory {mp:.0f}% used", "detail": ""})
    if sysd.get("swap_total_mb"):
        sp = 100 * sysd["swap_used_mb"] / sysd["swap_total_mb"]
        if sp >= 80:
            alerts.append({"level": "warn", "kind": "swap", "title": f"Swap {sp:.0f}% used", "detail": ""})
    la = (sysd.get("loadavg") or [0])[0]
    if sysd.get("cpus") and la > 2 * sysd["cpus"]:
        alerts.append({"level": "warn", "kind": "load", "title": f"Load {la:.1f} on {sysd['cpus']} CPUs", "detail": ""})
    for u in failed[:10]:
        alerts.append({"level": "crit", "kind": "unit", "title": f"{u} failed", "detail": "systemd", "target": u})
    for c in dk["containers"]:
        if c["health"] == "unhealthy":
            alerts.append({"level": "warn", "kind": "container", "title": f"{c['name']} unhealthy",
                           "detail": c["image"], "target": c["name"]})
        elif c["state"] in ("restarting", "dead"):
            alerts.append({"level": "crit", "kind": "container", "title": f"{c['name']} {c['state']}",
                           "detail": c["image"], "target": c["name"]})

    running = sum(1 for c in dk["containers"] if c["state"] == "running")
    return {
        "system": sysd, "latest": latest, "disks": ds, "alerts": alerts,
        "counts": {
            "containers_running": running, "containers_total": len(dk["containers"]),
            "containers_unhealthy": sum(1 for c in dk["containers"] if c["health"] == "unhealthy"),
            "units_failed": len(failed), "tmux": len(tmux),
            "helm_chats": sum(1 for t in tmux if t["is_helm"]),
            "peers_online": sum(1 for p in net["peers"] if p["online"]), "peers": len(net["peers"]),
        },
        "docker_age_s": dk["age_s"],
    }


_started = False


def start_background():
    global _started
    if _started:
        return
    _started = True
    threading.Thread(target=_sampler, name="helm-metrics", daemon=True).start()
    _kick("ps", _docker_ps)
