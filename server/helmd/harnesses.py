import json
import os
import re
import shutil
import subprocess
import time
import urllib.request

from . import config
from .adapters import (API_DEFAULT_MODEL, API_LAUNCHER, CODEX_BIN, VENICE_DEFAULT_MODEL,
                       VENICE_LAUNCHER)

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
    {"id": "glm", "name": "GLM-5.3-Flash (burst)", "command": "glm",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": "Modal GPU burst, cold start ~3 min"},
    {"id": "dsv", "name": "DeepSeek-V4.1 (burst)", "command": "dsv",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": "Modal GPU burst, cold start ~3 min"},
    {"id": "sukuna", "name": "Sukuna (offensive)", "command": "sukuna",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "note": "uncensored Venice model, no refusals"},
    {"id": "venice", "name": "Venice", "command": "v",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": VENICE_DEFAULT_MODEL, "note": "paid Venice credits per turn"},
    {"id": "api", "name": "API models", "command": "claude-burst",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": API_DEFAULT_MODEL, "note": "LiteLLM :4000 (DeepSeek, free tiers, Kaggle proxy)"},
    {"id": "dsh", "name": "DeepSeek Harness", "command": "dsh",
     "supports_profiles": False, "profiles": [], "models": [],
     "default_model": None, "available": False, "note": "phase 2"},
]

# Harnesses whose `command` is an absolute launcher path, not a $PATH binary.
_LAUNCHER_PATHS = {
    "glm": "/root/.local/bin/glm",
    "dsv": "/root/.local/bin/dsv",
    "sukuna": "/root/.local/bin/sukuna",
    "venice": VENICE_LAUNCHER,
    "api": API_LAUNCHER,
}

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


# ------------------------------------------------------------- model lists

MODEL_CACHE_TTL = 3600  # seconds; refresh a live model list at most hourly

VENICE_FALLBACK = [VENICE_DEFAULT_MODEL, "venice-uncensored-1-2",
                   "z-ai-glm-5-3-flash", "qwen-3-8-flash", "qwen3-coder-480b-a35b-instruct-turbo"]
API_FALLBACK = ["deepseek-v4-flash", "deepseek-v4-pro", "free-groq", "free-cerebras",
                "free-nvidia", "free-mistral", "free-openrouter", "worker-gemini",
                "kbench-claude-sonnet-5", "kbench-gemini-flash"]
CODEX_FALLBACK = ["gpt-6-luna", "gpt-5.6-terra", "gpt-5.6-luna"]

# LiteLLM :4000 ids that are not plain API models: burst-* are the Modal/Kaggle
# GPU harnesses (glm/dsv/...), pardalos-*/local-* are Pardalos-internal routes.
_API_EXCLUDE_PREFIXES = ("burst-", "pardalos-", "local-")


def _cached_models(name, fetch, fallback):
    """Model list from ~/.helm/models-<name>.json, refetched when older than
    MODEL_CACHE_TTL. A failed fetch serves the stale cache, then `fallback`."""
    path = config.HELM_HOME / f"models-{name}.json"
    cached = None
    try:
        cached = json.loads(path.read_text())
        if time.time() - cached.get("fetched", 0) < MODEL_CACHE_TTL and cached.get("models"):
            return cached["models"]
    except (OSError, ValueError, AttributeError):
        cached = None
    try:
        models = fetch()
    except Exception:
        models = []
    if models:
        try:
            path.write_text(json.dumps({"fetched": time.time(), "models": models}))
        except OSError:
            pass
        return models
    if cached and cached.get("models"):
        return cached["models"]
    return list(fallback)


def _fetch_venice():
    out = subprocess.run([VENICE_LAUNCHER, "--models"], capture_output=True,
                         text=True, timeout=20).stdout
    ids = [line.split()[0] for line in out.splitlines() if line.strip()]
    ids = [i for i in ids if re.fullmatch(r"[A-Za-z0-9._:/-]+", i)]
    if ids and VENICE_DEFAULT_MODEL not in ids:
        ids.insert(0, VENICE_DEFAULT_MODEL)
    return ids


def _fetch_api():
    req = urllib.request.Request("http://127.0.0.1:4000/v1/models",
                                 headers={"Authorization": "Bearer sk-none"})
    with urllib.request.urlopen(req, timeout=8) as r:
        data = json.load(r)
    ids = [m.get("id") for m in data.get("data", []) if isinstance(m, dict)]
    return [i for i in ids if i and not i.startswith(_API_EXCLUDE_PREFIXES)]


def _codex_models():
    """Visible models from Codex's own models cache, plus the configured
    default from config.toml. Both are local files, so no TTL cache needed."""
    home = os.path.expanduser("~/.codex")
    models, default = [], None
    try:
        with open(os.path.join(home, "models_cache.json")) as f:
            for m in json.load(f).get("models", []):
                slug = m.get("slug") or m.get("id")
                if slug and m.get("visibility", "list") == "list":
                    models.append(slug)
    except (OSError, ValueError, AttributeError):
        pass
    try:
        with open(os.path.join(home, "config.toml")) as f:
            for line in f:
                m = re.match(r'^model\s*=\s*"([^"]+)"', line)
                if m:
                    default = m.group(1)
                    break
    except OSError:
        pass
    if not models:
        models = list(CODEX_FALLBACK)
    if default and default not in models:
        models.insert(0, default)
    return models, default


def get_harnesses() -> list:
    out = []
    for h in _BASE:
        h = dict(h)
        if h["id"] in _LAUNCHER_PATHS:
            h.setdefault("available", os.access(_LAUNCHER_PATHS[h["id"]], os.X_OK))
        else:
            h.setdefault("available", shutil.which(h["command"]) is not None)
        if h["id"] == "codex":
            profiles = _cx_profiles()
            h["profiles"] = [p["name"] for p in profiles]
            h["profile_accounts"] = profiles
            # helmd's systemd PATH has no nvm bin, so check the resolved
            # binary the runner actually execs rather than $PATH.
            h["available"] = shutil.which("cx") is not None and os.access(CODEX_BIN, os.X_OK)
            h["models"], h["default_model"] = _codex_models()
        elif h["id"] == "venice":
            h["models"] = _cached_models("venice", _fetch_venice, VENICE_FALLBACK)
        elif h["id"] == "api":
            h["models"] = _cached_models("api", _fetch_api, API_FALLBACK)
        out.append(h)
    return out
