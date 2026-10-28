import re
import shutil
import subprocess

# Static registry per PROTOCOL.md "v1 harness ids".
_BASE = [
    {"id": "claude", "name": "Claude Code", "command": "claude",
     "supports_profiles": False, "profiles": [], "models": ["sonnet", "haiku", "opus"],
     "default_model": None, "note": None},
    {"id": "ds", "name": "Claude via DeepSeek proxy", "command": "ds",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": None},
    {"id": "cc", "name": "Claude via Groq proxy", "command": "cc",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": None},
    {"id": "agy", "name": "Agy", "command": "agy",
     "supports_profiles": False, "profiles": [],
     "models": ["gemini-3.8-flash-low", "gemini-3.8-flash-medium", "gemini-3.8-flash-high",
                "claude-sonnet-4-6", "claude-opus-4-6-thinking", "gpt-oss-120b-medium"],
     "default_model": None, "note": None},
    {"id": "codex", "name": "Codex", "command": "codex",
     "supports_profiles": True, "profiles": [], "models": [],
     "default_model": None, "note": None},
    {"id": "dsh", "name": "DeepSeek Harness", "command": "dsh",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "available": False, "note": "phase 2"},
]

_CX_LINE_RE = re.compile(r"^(\S+)\s+(\S+)\s")


def _cx_profiles() -> list:
    """Best-effort parse of `cx ls` output: PROFILE ACCOUNT AUTH CODEX_HOME."""
    cx = shutil.which("cx")
    if not cx:
        return []
    try:
        out = subprocess.run([cx, "ls"], capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return []
    profiles = []
    for line in out.splitlines():
        if not line.strip() or line.strip().upper().startswith("PROFILE"):
            continue
        m = _CX_LINE_RE.match(line)
        if not m:
            continue
        name, account = m.group(1), m.group(2)
        profiles.append({"name": name, "account": account})
    return profiles


def get_harnesses() -> list:
    out = []
    for h in _BASE:
        h = dict(h)
        h.setdefault("available", shutil.which(h["command"]) is not None)
        if h["id"] == "codex":
            profiles = _cx_profiles()
            h["profiles"] = [p["name"] for p in profiles]
            h["profile_accounts"] = profiles
            h["available"] = shutil.which("cx") is not None and shutil.which("codex") is not None
        out.append(h)
    return out
