"""Box remote-control surface: system status, tmux sessions, systemd services,
Claude Code history, GPU-burst control, and an arbitrary-shell escape hatch.

Everything here is a thin, bounded wrapper over local commands. Output is
truncated so a phone over the public mTLS route never pulls a megabyte. All of
it sits behind the same bearer token as the rest of helmd (see main.py); per the
owner's instruction the box-control surface is reachable on both the wg0 and
public routes.
"""
import glob
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path

# ----------------------------------------------------------------- system

def _run(cmd, timeout=10):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except Exception:
        return ""


def system_status() -> dict:
    """Uptime, load, memory, swap and root-disk usage, parsed into numbers."""
    out = {}

    # uptime / load
    try:
        with open("/proc/uptime") as f:
            out["uptime_seconds"] = float(f.read().split()[0])
    except Exception:
        out["uptime_seconds"] = None
    try:
        out["loadavg"] = os.getloadavg()
    except Exception:
        out["loadavg"] = None
    out["cpus"] = os.cpu_count()

    # memory + swap (kB from /proc/meminfo)
    mem = {}
    try:
        for line in open("/proc/meminfo"):
            k, _, v = line.partition(":")
            mem[k.strip()] = int(v.strip().split()[0])  # kB
    except Exception:
        pass
    if mem:
        out["mem_total_mb"] = mem.get("MemTotal", 0) // 1024
        out["mem_available_mb"] = mem.get("MemAvailable", 0) // 1024
        out["mem_used_mb"] = (mem.get("MemTotal", 0) - mem.get("MemAvailable", 0)) // 1024
        out["swap_total_mb"] = mem.get("SwapTotal", 0) // 1024
        out["swap_used_mb"] = (mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)) // 1024

    # root disk
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        out["disk_total_gb"] = round(total / 1e9, 1)
        out["disk_free_gb"] = round(free / 1e9, 1)
        out["disk_used_pct"] = round(100 * (total - free) / total) if total else None
    except Exception:
        pass

    out["hostname"] = _run(["hostname"]) or os.uname().nodename
    out["now"] = time.time()
    return out


# ----------------------------------------------------------------- tmux

_TMUX_FMT = "#{session_name}\t#{session_windows}\t#{session_created}\t#{session_attached}"


def tmux_sessions() -> list:
    out = _run(["tmux", "list-sessions", "-F", _TMUX_FMT])
    sessions = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        name, windows, created, attached = parts[:4]
        sessions.append({
            "name": name,
            "windows": int(windows) if windows.isdigit() else 0,
            "created": float(created) if created.replace(".", "").isdigit() else None,
            "attached": attached not in ("0", ""),
            "is_helm": name.startswith("hx-"),
        })
    sessions.sort(key=lambda s: (not s["attached"], s["name"]))
    return sessions


def tmux_capture(name: str, lines: int = 200) -> str:
    """Last `lines` of a tmux pane (the live scrollback), bounded."""
    lines = max(1, min(lines, 2000))
    out = _run(["tmux", "capture-pane", "-p", "-t", name, "-S", f"-{lines}"], timeout=10)
    return out[-20000:]


def tmux_kill(name: str) -> bool:
    r = subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)
    return r.returncode == 0


def tmux_send(name: str, keys: str) -> bool:
    """Send literal keys to a tmux session, then Enter."""
    r = subprocess.run(["tmux", "send-keys", "-t", name, keys, "Enter"],
                       capture_output=True)
    return r.returncode == 0


# ----------------------------------------------------------------- services

# Curated set of services worth controlling from the phone. Anything else can
# still be reached via /box/services/<name>/<action> by name.
WATCHED_SERVICES = [
    "helmd",
    "venice-proxy",
    "llm-burst-router",
    "pardalos-freeproxy",
    "caddy",
    "wg-quick@wg0",
    "claude-watchdog",
]

_SERVICE_NAME_RE = re.compile(r"^[A-Za-z0-9@._\-]+$")
VALID_SERVICE_ACTIONS = {"start", "stop", "restart"}


def service_status(names=None) -> list:
    names = names or WATCHED_SERVICES
    out = []
    for n in names:
        active = _run(["systemctl", "is-active", n]) or "unknown"
        enabled = _run(["systemctl", "is-enabled", n]) or "unknown"
        out.append({"name": n, "active": active, "enabled": enabled})
    return out


def service_action(name: str, action: str) -> dict:
    if not _SERVICE_NAME_RE.match(name):
        return {"ok": False, "error": "bad service name"}
    if action not in VALID_SERVICE_ACTIONS:
        return {"ok": False, "error": "bad action"}
    r = subprocess.run(["systemctl", action, name], capture_output=True, text=True, timeout=30)
    active = _run(["systemctl", "is-active", name])
    return {"ok": r.returncode == 0, "active": active,
            "error": (r.stderr or r.stdout).strip()[:500] if r.returncode else None}


# ----------------------------------------------------------- claude history

_CLAUDE_PROJECTS = Path.home() / ".claude" / "projects"


def _first_user_text(path: Path) -> str:
    """Pull the first human message out of a Claude Code transcript jsonl."""
    try:
        with open(path) as f:
            for _ in range(200):
                line = f.readline()
                if not line:
                    break
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                if obj.get("type") != "user":
                    continue
                msg = obj.get("message", {})
                content = msg.get("content")
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    text = " ".join(
                        b.get("text", "") for b in content
                        if isinstance(b, dict) and b.get("type") == "text")
                else:
                    text = ""
                text = text.strip()
                # skip command/system noise
                if text and not text.startswith(("<", "Caveat:", "/")):
                    return text[:120]
    except Exception:
        pass
    return ""


def claude_sessions(limit: int = 40) -> list:
    """Recent Claude Code sessions across all projects, newest first."""
    rows = []
    for jf in glob.glob(str(_CLAUDE_PROJECTS / "*" / "*.jsonl")):
        try:
            stt = os.stat(jf)
        except OSError:
            continue
        p = Path(jf)
        rows.append({
            "id": p.stem,
            "project": p.parent.name,
            "path": jf,
            "modified": stt.st_mtime,
            "size_kb": round(stt.st_size / 1024, 1),
        })
    rows.sort(key=lambda r: r["modified"], reverse=True)
    rows = rows[:limit]
    for r in rows:
        r["summary"] = _first_user_text(Path(r["path"]))
    return rows


def claude_transcript(project: str, sid: str, tail: int = 60) -> dict:
    """Readable tail of one Claude Code session: user/assistant text turns."""
    if not re.match(r"^[A-Za-z0-9@._\-]+$", project) or not re.match(r"^[A-Za-z0-9\-]+$", sid):
        return {"error": "bad id"}
    path = _CLAUDE_PROJECTS / project / f"{sid}.jsonl"
    if not path.exists():
        return {"error": "not found"}
    turns = []
    try:
        for line in open(path):
            try:
                obj = json.loads(line)
            except Exception:
                continue
            t = obj.get("type")
            if t not in ("user", "assistant"):
                continue
            msg = obj.get("message", {})
            content = msg.get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = " ".join(
                    b.get("text", "") for b in content
                    if isinstance(b, dict) and b.get("type") == "text")
            else:
                text = ""
            text = text.strip()
            if not text or text.startswith(("<", "Caveat:")):
                continue
            turns.append({"role": t, "text": text[:4000], "ts": obj.get("timestamp")})
    except Exception as e:
        return {"error": str(e)[:200]}
    return {"id": sid, "project": project, "turns": turns[-max(1, min(tail, 500)):]}


# ----------------------------------------------------------- GPU burst

# model key -> (launcher path, session.py LLM_BURST_SESSION_MODEL target)
BURST_MODELS = {
    "glm": {"launcher": "/root/.local/bin/glm", "target": "glm53-flash"},
    "dsv": {"launcher": "/root/.local/bin/dsv", "target": "dsv41-flash"},
}
_SESSION_PY = "/root/projects/llm-burst/session.py"
VALID_BURST_ACTIONS = {"warm", "status", "release"}


def burst_status() -> list:
    out = []
    for key, cfg in BURST_MODELS.items():
        if not os.access(cfg["launcher"], os.X_OK):
            continue
        env = dict(os.environ, LLM_BURST_SESSION_MODEL=cfg["target"])
        txt = ""
        try:
            r = subprocess.run(["python3", _SESSION_PY, "status"], capture_output=True,
                               text=True, timeout=25, env=env)
            txt = (r.stdout + r.stderr).strip()
        except Exception as e:
            txt = f"error: {e}"
        held = "pinned" in txt.lower() or "held" in txt.lower() or "min_containers=1" in txt
        out.append({"model": key, "target": cfg["target"], "held": held, "detail": txt[:400]})
    return out


def burst_action(model: str, action: str) -> dict:
    if model not in BURST_MODELS:
        return {"ok": False, "error": "unknown burst model"}
    if action not in VALID_BURST_ACTIONS:
        return {"ok": False, "error": "bad action"}
    cfg = BURST_MODELS[model]
    env = dict(os.environ, LLM_BURST_SESSION_MODEL=cfg["target"])
    if action == "warm":
        # Fire-and-forget: glm warm backgrounds a health ping that triggers a
        # cold start. Don't block the request on the ~3 min boot.
        try:
            subprocess.Popen([cfg["launcher"], "warm"],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return {"ok": True, "detail": "warming in background (several minutes)"}
        except Exception as e:
            return {"ok": False, "error": str(e)[:300]}
    # status / release go through session.py directly, bounded.
    try:
        r = subprocess.run(["python3", _SESSION_PY, action], capture_output=True,
                           text=True, timeout=60, env=env)
        return {"ok": r.returncode == 0, "detail": (r.stdout + r.stderr).strip()[:600]}
    except Exception as e:
        return {"ok": False, "error": str(e)[:300]}


# ----------------------------------------------------------- shell escape hatch

def run_shell(cmd: str, cwd: str = None, timeout: int = 120) -> dict:
    """Arbitrary `bash -lc` on the box. The catch-all remote control."""
    timeout = max(1, min(timeout, 600))
    cwd = cwd or str(Path.home())
    if not os.path.isdir(cwd):
        cwd = str(Path.home())
    try:
        r = subprocess.run(["bash", "-lc", cmd], cwd=cwd, capture_output=True,
                           text=True, timeout=timeout)
        out = (r.stdout + ("\n" + r.stderr if r.stderr else ""))
        return {"ok": r.returncode == 0, "exit": r.returncode, "output": out[-20000:]}
    except subprocess.TimeoutExpired:
        return {"ok": False, "exit": -1, "output": f"[timed out after {timeout}s]"}
    except Exception as e:
        return {"ok": False, "exit": -1, "output": str(e)[:1000]}
