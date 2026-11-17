"""Drop: a Telegram-style thread of files and notes between the phone and the box.

Everything sent through Drop lives in one folder (DROP_DIR, default /root/drop):
  /root/drop/            files sent from the phone
  /root/drop/to-phone/   copies of box files sent to the phone (hardlinked when possible)
The thread itself is $HELM_HOME/drop.jsonl, one item per line. Every write takes an
flock, so helmd and the `helm-send` CLI can both append safely without talking HTTP.
"""
import fcntl
import json
import os
import shutil
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Optional

from . import config, files

DROP_DIR = Path(os.environ.get("HELM_DROP_DIR", "/root/drop"))
OUT_DIR = DROP_DIR / "to-phone"
LOG = config.HELM_HOME / "drop.jsonl"
LOCK = config.HELM_HOME / "drop.lock"
SEQ = config.HELM_HOME / "drop.seq"  # ids never repeat, even after deletes
MAX_NOTE = 20000


class DropError(Exception):
    def __init__(self, status: int, msg: str):
        super().__init__(msg)
        self.status, self.msg = status, msg


@contextmanager
def _locked():
    config.HELM_HOME.mkdir(parents=True, exist_ok=True)
    with LOCK.open("a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def _read() -> list:
    if not LOG.exists():
        return []
    out = []
    for line in LOG.read_text().splitlines():
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def _decorate(item: dict) -> dict:
    if item.get("path"):
        p = Path(item["path"])
        item = {**item, "exists": p.exists(), "is_dir": p.is_dir()}
    return item


def _append(item: dict) -> dict:
    """Assigns the next id and appends. Caller holds the lock."""
    items = _read()
    last = max(items[-1]["id"] if items else 0, int(SEQ.read_text() or 0) if SEQ.exists() else 0)
    item = {"id": last + 1, "ts": time.time(), **item}
    SEQ.write_text(str(last + 1))
    with LOG.open("a") as fh:
        fh.write(json.dumps(item) + "\n")
    return item


def list_items(after: int = 0) -> dict:
    with _locked():
        items = _read()
        seq = int(SEQ.read_text() or 0) if SEQ.exists() else 0
    return {"dir": str(DROP_DIR), "last_id": max(seq, items[-1]["id"] if items else 0),
            "items": [_decorate(i) for i in items if i["id"] > after]}


def incoming_target(filename: Optional[str]) -> Path:
    DROP_DIR.mkdir(parents=True, exist_ok=True)
    name = Path(filename or "").name or f"drop-{int(time.time())}"
    return files.unique(DROP_DIR / name)


def record_incoming(dest: Path, caption: str = "") -> dict:
    with _locked():
        return _decorate(_append({"from": "phone", "kind": "file", "name": dest.name,
                                  "path": str(dest), "size": dest.stat().st_size,
                                  "text": caption.strip()[:MAX_NOTE]}))


def note(text: str, sender: str = "phone") -> dict:
    text = (text or "").strip()
    if not text:
        raise DropError(400, "empty note")
    if sender not in ("phone", "box"):
        raise DropError(400, "from must be phone or box")
    with _locked():
        return _append({"from": sender, "kind": "note", "text": text[:MAX_NOTE]})


def _size(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file() and not f.is_symlink())


def _link_or_copy(src: str, dst: str):
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def send_to_phone(path: str, caption: str = "", copy: bool = True) -> dict:
    """Puts a box file or folder in the thread. With copy (the default) a snapshot goes
    into to-phone/ so the bubble keeps working if the original moves or changes."""
    src = Path(path).expanduser()
    if not src.is_absolute():
        src = Path.cwd() / src
    src = src.resolve()
    if not src.exists():
        raise DropError(404, f"{src} not found")
    dest = src
    if copy and not src.is_relative_to(DROP_DIR):
        OUT_DIR.mkdir(parents=True, exist_ok=True)
        dest = files.unique(OUT_DIR / src.name)
        if src.is_dir():
            shutil.copytree(src, dest, symlinks=True, copy_function=_link_or_copy)
        else:
            _link_or_copy(str(src), str(dest))
    with _locked():
        return _decorate(_append({"from": "box", "kind": "file", "name": dest.name,
                                  "path": str(dest), "size": _size(dest),
                                  "text": (caption or "").strip()[:MAX_NOTE]}))


def delete(item_id: int, delete_file: bool = False) -> dict:
    with _locked():
        items = _read()
        hit = next((i for i in items if i["id"] == item_id), None)
        if not hit:
            raise DropError(404, "no such item")
        if delete_file and hit.get("path"):
            p = Path(hit["path"])
            # Only files Drop owns; a no-copy send points at the user's own file.
            if p.exists() and p.resolve().is_relative_to(DROP_DIR.resolve()):
                files.trash(str(p))
        tmp = LOG.with_suffix(".tmp")
        tmp.write_text("".join(json.dumps(i) + "\n" for i in items if i["id"] != item_id))
        os.replace(tmp, LOG)
    return {"ok": True}
