import os
from pathlib import Path

HELM_HOME = Path(os.environ.get("HELM_HOME", Path.home() / ".helm"))
SESSIONS_DIR = HELM_HOME / "sessions"
TOKEN_FILE = HELM_HOME / "token"

BIND_HOST = "10.66.66.1"
BIND_PORT = 3340

HELM_RUNNER = str(Path(__file__).resolve().parent.parent / "helm-runner")


def ensure_dirs():
    SESSIONS_DIR.mkdir(parents=True, exist_ok=True)


def load_token() -> str:
    if not TOKEN_FILE.exists():
        raise RuntimeError(f"token file missing: {TOKEN_FILE}")
    return TOKEN_FILE.read_text().strip()


def session_dir(sid: str) -> Path:
    return SESSIONS_DIR / sid


def meta_path(sid: str) -> Path:
    return session_dir(sid) / "meta.json"


def events_path(sid: str) -> Path:
    return session_dir(sid) / "events.jsonl"


def inbox_path(sid: str) -> Path:
    return session_dir(sid) / "inbox"


def uploads_dir(sid: str) -> Path:
    return session_dir(sid) / "uploads"
