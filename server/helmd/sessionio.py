"""Shared helpers for reading/writing session state on disk.

Used by both helmd (the API server) and helm-runner (the per-session
process running inside tmux). Keeping this logic in one place means both
sides agree on the on-disk format.
"""
import fcntl
import json
import os
import threading
import time
from pathlib import Path
from typing import Optional

from . import config


def _lock(fh):
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)


def read_meta(sid: str) -> Optional[dict]:
    p = config.meta_path(sid)
    if not p.exists():
        return None
    with open(p, "r") as fh:
        _lock(fh)
        try:
            return json.load(fh)
        except json.JSONDecodeError:
            return None


def write_meta(sid: str, meta: dict) -> None:
    p = config.meta_path(sid)
    tmp = p.with_suffix(".tmp")
    with open(tmp, "w") as fh:
        _lock(fh)
        json.dump(meta, fh)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, p)


def update_meta(sid: str, **fields) -> dict:
    """Read-modify-write meta.json under a lock to avoid lost updates
    between helmd and helm-runner."""
    p = config.meta_path(sid)
    with open(p, "r+") as fh:
        _lock(fh)
        fh.seek(0)
        meta = json.load(fh)
        meta.update(fields)
        meta["updated"] = time.time()
        fh.seek(0)
        fh.truncate()
        json.dump(meta, fh)
        fh.flush()
        os.fsync(fh.fileno())
    return meta


def append_event(sid: str, event: dict) -> dict:
    """Append one event to events.jsonl, assigning the next seq, and bump
    meta.json's last_seq + updated. Returns the full event as written."""
    p = config.events_path(sid)
    meta_p = config.meta_path(sid)
    with open(meta_p, "r+") as mfh:
        _lock(mfh)
        mfh.seek(0)
        meta = json.load(mfh)
        seq = meta.get("last_seq", 0) + 1
        event = dict(event)
        event["seq"] = seq
        event.setdefault("ts", time.time())
        with open(p, "a") as efh:
            efh.write(json.dumps(event) + "\n")
            efh.flush()
            os.fsync(efh.fileno())
        meta["last_seq"] = seq
        meta["updated"] = time.time()
        mfh.seek(0)
        mfh.truncate()
        json.dump(meta, mfh)
        mfh.flush()
        os.fsync(mfh.fileno())
    return event


def read_events(sid: str, after: int = 0, limit: int = 500) -> list:
    p = config.events_path(sid)
    if not p.exists():
        return []
    out = []
    with open(p, "r") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("seq", 0) > after:
                out.append(ev)
                if len(out) >= limit:
                    break
    return out


_inbox_lock = threading.Lock()


def write_inbox(sid: str, obj: dict, timeout: float = 12.0) -> bool:
    """Write one line to the session's inbox FIFO. Retries opening
    non-blocking until the runner's reader connects, or times out.

    The open is non-blocking (so a missing reader times out instead of
    hanging), but the write itself is blocking and looped: a single
    non-blocking write of a line bigger than the pipe buffer (~64KB) used to
    be cut short, losing the message and corrupting the next one. Writers
    are serialised because writes above PIPE_BUF are not atomic."""
    path = str(config.inbox_path(sid))
    line = (json.dumps(obj) + "\n").encode()
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            time.sleep(0.05)
            continue
        try:
            os.set_blocking(fd, True)
            with _inbox_lock:
                view = memoryview(line)
                while view:
                    n = os.write(fd, view)
                    view = view[n:]
            return True
        except OSError:  # reader went away mid-write (EPIPE)
            return False
        finally:
            os.close(fd)
    return False


def tail_events(sid: str, offset: int, after: int) -> tuple:
    """Events with seq > after found from byte `offset` on, plus the offset
    to resume from. Only complete lines are consumed, so a line still being
    appended is picked up whole on the next call. Lets the WebSocket poll
    read just the new bytes instead of re-parsing the whole file 5x/second."""
    p = config.events_path(sid)
    try:
        size = p.stat().st_size
    except FileNotFoundError:
        return [], 0
    if size < offset:  # truncated or replaced: start over, seq filter dedupes
        offset = 0
    if size == offset:
        return [], offset
    with open(p, "rb") as fh:
        fh.seek(offset)
        data = fh.read(size - offset)
    end = data.rfind(b"\n")
    if end < 0:
        return [], offset
    out = []
    for raw in data[:end].split(b"\n"):
        raw = raw.strip()
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue
        if ev.get("seq", 0) > after:
            out.append(ev)
    return out, offset + end + 1
