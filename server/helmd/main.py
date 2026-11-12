import asyncio
import hmac
import json
import os
import re
import shutil
import signal
import subprocess
import time
import urllib.parse
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Query, Request, UploadFile, File, Form, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse

from pydantic import BaseModel

from . import adapters, box, config, files, reaper, sessionio
from .harnesses import get_harnesses
from .idgen import new_id

app = FastAPI()

VALID_PERMISSIONS = {"bypass", "acceptEdits", "default", "plan"}
VALID_HARNESSES = {h["id"] for h in get_harnesses()}
SID_RE = re.compile(r"^[a-z0-9]{1,32}$")


# ---------- auth ----------

def check_auth(authorization: Optional[str] = Header(None)):
    token = config.load_token()
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "missing bearer token")
    if not hmac.compare_digest(authorization[7:].encode(), token.encode()):
        raise HTTPException(401, "bad token")


# ---------- tmux helpers ----------

def tmux_has_session(name: str) -> bool:
    r = subprocess.run(["tmux", "has-session", "-t", name], capture_output=True)
    return r.returncode == 0


def tmux_live_runners() -> set:
    """Names of tmux sessions whose pane is still running. Sessions are made
    with remain-on-exit, so a runner that exited leaves a dead pane behind and
    has-session keeps saying yes; only pane_dead tells the truth."""
    r = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{session_name} #{pane_dead}"],
                       capture_output=True, text=True, errors="replace")
    if r.returncode != 0 and not ("no server" in r.stderr or "No such file" in r.stderr):
        return None  # tmux trouble: unknown, so callers must not act on it
    live = set()
    for line in r.stdout.splitlines():
        name, _, dead = line.rpartition(" ")
        if dead == "0":
            live.add(name)
    return live


def tmux_runner_alive(name: str) -> bool:
    live = tmux_live_runners()
    return tmux_has_session(name) if live is None else name in live


def _reconcile(meta: dict, live: set, detail: str) -> dict:
    """Mark a session exited when it claims idle/running but its runner is
    gone, so the app shows "exited" (and offers resume) instead of a chat that
    silently swallows messages. "starting" is left alone: the runner may still
    be coming up."""
    if live is not None and meta.get("state") in ("running", "idle") and f"hx-{meta['id']}" not in live:
        sessionio.update_meta(meta["id"], state="exited")
        sessionio.append_event(meta["id"], {"type": "status", "state": "exited", "detail": detail})
        meta = sessionio.read_meta(meta["id"]) or meta
    return meta


def tmux_kill_session(name: str) -> None:
    subprocess.run(["tmux", "kill-session", "-t", name], capture_output=True)


def tmux_start_runner(sid: str, cwd: str) -> None:
    name = f"hx-{sid}"
    if tmux_has_session(name):
        tmux_kill_session(name)
    Path(cwd).mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", name, "-c", cwd,
         "-e", f"HELM_HOME={config.HELM_HOME}", config.HELM_RUNNER, sid],
        check=True,
    )
    subprocess.run(["tmux", "set-option", "-t", name, "remain-on-exit", "on"], capture_output=True)


# ---------- startup ----------

@app.on_event("startup")
def on_startup():
    config.ensure_dirs()
    config.load_token()  # fail fast if missing
    reaper.start_background()
    # Reconcile: any session claiming to be alive but with no tmux session
    # behind it (e.g. the box rebooted) is marked exited.
    if not config.SESSIONS_DIR.exists():
        return
    live = tmux_live_runners()
    for d in config.SESSIONS_DIR.iterdir():
        if not d.is_dir():
            continue
        sid = d.name
        meta = sessionio.read_meta(sid)
        if not meta:
            continue
        if live is None:
            break
        if meta.get("state") in ("starting", "running", "idle") and f"hx-{sid}" not in live:
            sessionio.update_meta(sid, state="exited")
            sessionio.append_event(sid, {"type": "status", "state": "exited",
                                          "detail": "helmd restart: runner/tmux not found"})


# ---------- REST ----------

@app.get("/health")
def health():
    return {"ok": True, "version": "1"}


@app.get("/harnesses")
def harnesses(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return get_harnesses()


@app.get("/sessions")
def list_sessions(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    out = []
    if config.SESSIONS_DIR.exists():
        live = tmux_live_runners()
        for d in config.SESSIONS_DIR.iterdir():
            meta = sessionio.read_meta(d.name)
            if meta:
                out.append(_reconcile(meta, live, "runner is not running"))
    out.sort(key=lambda m: m.get("updated", 0), reverse=True)
    return out


@app.post("/sessions")
async def create_session(request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    body = await request.json()
    harness = body.get("harness")
    if harness not in VALID_HARNESSES:
        raise HTTPException(400, f"unknown harness {harness!r}")
    if not next((h for h in get_harnesses() if h["id"] == harness), {}).get("available", True):
        raise HTTPException(400, f"harness {harness!r} is not available on this box")
    permission = body.get("permission", "bypass")
    if permission not in VALID_PERMISSIONS:
        raise HTTPException(400, f"bad permission {permission!r}")
    cwd = body.get("cwd") or str(Path.home())
    sid = new_id()
    now = time.time()
    text = body.get("text")
    title = (text or "").strip()[:60] or harness
    meta = {
        "id": sid, "title": title, "harness": harness,
        "profile": body.get("profile"), "model": body.get("model"),
        "cwd": cwd, "permission": permission, "state": "starting",
        "created": now, "updated": now, "last_seq": 0,
        "native_session_id": None, "tmux": f"hx-{sid}",
    }
    sdir = config.session_dir(sid)
    sdir.mkdir(parents=True, exist_ok=True)
    config.uploads_dir(sid).mkdir(parents=True, exist_ok=True)
    sessionio.write_meta(sid, meta)
    config.events_path(sid).touch()
    os.mkfifo(str(config.inbox_path(sid)))
    tmux_start_runner(sid, cwd)
    if text:
        ok = await asyncio.get_event_loop().run_in_executor(
            None, sessionio.write_inbox, sid, {"op": "message", "text": text,
                                                "attachments": body.get("attachments", [])})
        if not ok:
            sessionio.append_event(sid, {"type": "error", "text": "runner did not come up to accept first message"})
    return sessionio.read_meta(sid)


def _require_session(sid: str) -> dict:
    if not SID_RE.match(sid or ""):
        raise HTTPException(404, "no such session")
    meta = sessionio.read_meta(sid)
    if not meta:
        raise HTTPException(404, "no such session")
    return meta


@app.get("/sessions/{sid}")
def get_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _reconcile(_require_session(sid), tmux_live_runners(), "runner is not running")


@app.patch("/sessions/{sid}")
async def patch_session(sid: str, request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    body = await request.json()
    fields = {}
    if "title" in body:
        fields["title"] = body["title"]
    return sessionio.update_meta(sid, **fields)


@app.delete("/sessions/{sid}")
def delete_session(sid: str, purge: int = Query(0), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    tmux_kill_session(f"hx-{sid}")
    if purge:
        shutil.rmtree(config.session_dir(sid), ignore_errors=True)
    elif meta.get("state") != "exited":
        sessionio.update_meta(sid, state="exited")
        sessionio.append_event(sid, {"type": "status", "state": "exited", "detail": "stopped"})
    return {"ok": True}


@app.get("/sessions/{sid}/events")
def get_events(sid: str, after: int = 0, limit: int = 500, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    return sessionio.read_events(sid, after=after, limit=limit)


@app.post("/sessions/{sid}/messages")
async def post_message(sid: str, request: Request, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    body = await request.json()
    loop = asyncio.get_event_loop()
    revived = await loop.run_in_executor(None, _ensure_runner, sid, meta)
    ok = await loop.run_in_executor(
        None, sessionio.write_inbox, sid, _message_op(body), 30.0 if revived else 12.0)
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    # Messages sent mid-turn are queued by the runner, not rejected.
    return {"ok": True, "queued": meta.get("state") == "running" or bool(meta.get("queue")),
            "revived": revived}


def _ensure_runner(sid: str, meta: dict) -> bool:
    """If the chat's tmux runner is gone (tmux server restart, reaper, crash),
    restart it so the message is delivered instead of timing out with 503.
    Returns True when a runner was (re)started."""
    if tmux_runner_alive(f"hx-{sid}"):
        return False
    sessionio.append_event(sid, {"type": "status", "state": "starting",
                                  "detail": "runner was not running; restarted on send"})
    sessionio.update_meta(sid, state="starting")
    tmux_start_runner(sid, meta["cwd"])
    return True


def _message_op(body: dict) -> dict:
    return {"op": "message", "text": body.get("text", ""),
            "attachments": body.get("attachments", []), "client_id": body.get("client_id")}


@app.delete("/sessions/{sid}/queue/{qid}")
async def dequeue_one(sid: str, qid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "dequeue", "queue_id": qid})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.delete("/sessions/{sid}/queue")
async def dequeue_all(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "dequeue", "queue_id": None})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.get("/sessions/{sid}/commands")
def session_commands(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    return {"commands": adapters.known_commands(meta), "shell": True}


@app.post("/sessions/{sid}/interrupt")
async def interrupt_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(sid)
    ok = await asyncio.get_event_loop().run_in_executor(
        None, sessionio.write_inbox, sid, {"op": "interrupt"})
    if not ok:
        raise HTTPException(503, "runner not accepting input")
    return {"ok": True}


@app.post("/sessions/{sid}/resume")
def resume_session(sid: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    meta = _require_session(sid)
    sessionio.update_meta(sid, state="starting")
    tmux_start_runner(sid, meta["cwd"])
    return sessionio.read_meta(sid)


@app.post("/upload")
async def upload(file: UploadFile = File(...), session_id: str = Form(...),
                  authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    _require_session(session_id)
    dest = await _save_upload(file, config.uploads_dir(session_id))
    return {"path": str(dest)}


async def _save_upload(file: UploadFile, udir: Path) -> Path:
    """Streams an upload into udir without overwriting: a clash becomes name-1.ext."""
    udir.mkdir(parents=True, exist_ok=True)
    name = Path(file.filename or "").name or f"upload-{int(time.time())}"
    stem, suffix = Path(name).stem, Path(name).suffix
    dest, n = udir / name, 1
    while dest.exists():
        dest, n = udir / f"{stem}-{n}{suffix}", n + 1
    with dest.open("wb") as out:
        while chunk := await file.read(1 << 20):
            out.write(chunk)
    return dest


@app.get("/dirs")
def dirs(path: str = Query(str(Path.home())), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    p = Path(path)
    if not p.is_dir():
        raise HTTPException(400, "not a directory")
    entries = []
    try:
        for e in sorted(p.iterdir(), key=lambda x: x.name.lower()):
            if e.is_dir():
                entries.append({"name": e.name, "is_dir": True})
    except PermissionError:
        pass
    return {"path": str(p), "entries": entries}


@app.get("/quota")
def quota(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    qa = shutil.which("quota-axi")
    if not qa:
        return {}
    try:
        out = subprocess.run([qa, "--json"], capture_output=True, text=True, timeout=15).stdout
        return json.loads(out)
    except Exception:
        return {}


# ---------- box remote control ----------

@app.get("/box/system")
def box_system(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return box.system_status()


@app.get("/box/tmux")
def box_tmux(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"sessions": reaper.sessions_with_idle()}


class ReaperConfig(BaseModel):
    enabled: Optional[bool] = None
    idle_hours: Optional[float] = None
    include_non_helm: Optional[bool] = None


@app.get("/box/reaper")
def box_reaper(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return reaper.status()


@app.put("/box/reaper")
def box_reaper_set(body: ReaperConfig, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    reaper.save(**{k: v for k, v in body.dict().items() if v is not None})
    return reaper.status()


@app.post("/box/reaper/run")
def box_reaper_run(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"killed": reaper.run_once(), **reaper.status()}


@app.get("/box/tmux/{name}/capture")
def box_tmux_capture(name: str, lines: int = Query(200),
                     authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"name": name, "text": box.tmux_capture(name, lines)}


class TmuxSend(BaseModel):
    keys: str


@app.post("/box/tmux/{name}/send")
def box_tmux_send(name: str, body: TmuxSend, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"ok": box.tmux_send(name, body.keys)}


@app.delete("/box/tmux/{name}")
def box_tmux_kill(name: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"ok": box.tmux_kill(name)}


@app.get("/box/services")
def box_services(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"services": box.service_status()}


@app.post("/box/services/{name}/{action}")
def box_service_action(name: str, action: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return box.service_action(name, action)


@app.get("/box/claude-sessions")
def box_claude_sessions(limit: int = Query(40), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"sessions": box.claude_sessions(limit)}


@app.get("/box/claude-sessions/{project}/{sid}")
def box_claude_transcript(project: str, sid: str, tail: int = Query(60),
                          authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return box.claude_transcript(project, sid, tail)


@app.get("/box/burst")
def box_burst(authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"models": box.burst_status()}


@app.post("/box/burst/{model}/{action}")
def box_burst_action(model: str, action: str, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return box.burst_action(model, action)


class ShellBody(BaseModel):
    cmd: str
    cwd: Optional[str] = None
    timeout: int = 120


@app.post("/box/shell")
def box_shell(body: ShellBody, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return box.run_shell(body.cmd, body.cwd, body.timeout)


@app.post("/box/upload")
async def box_upload(file: UploadFile = File(...), dir: str = Form(config.BOX_UPLOADS_DIR),
                     rel: Optional[str] = Form(None), overwrite: bool = Form(False),
                     authorization: Optional[str] = Header(None)):
    """rel (e.g. "Folder/sub/a.pdf") rebuilds a folder tree under dir, one file per request."""
    check_auth(authorization)
    dest = _fs(files.upload_target, dir, file.filename, rel, overwrite)
    part = dest.with_name(f".{dest.name}.helmpart")
    try:
        with part.open("wb") as out:
            while chunk := await file.read(1 << 20):
                out.write(chunk)
        os.replace(part, dest)
    finally:
        part.unlink(missing_ok=True)
    return {"path": str(dest), "size": dest.stat().st_size}


# ---------- file manager ----------

def _fs(fn, *args):
    try:
        return fn(*args)
    except files.FsError as e:
        raise HTTPException(e.status, e.msg)
    except PermissionError:
        raise HTTPException(403, "permission denied")
    except FileNotFoundError:
        raise HTTPException(404, "not found")


@app.get("/box/fs/list")
def fs_list(path: str = Query(str(Path.home())), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _fs(files.list_dir, path)


@app.get("/box/fs/tree")
def fs_tree(path: str = Query(...), authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return _fs(files.tree, path)


@app.get("/box/fs/download")
def fs_download(path: str = Query(...), authorization: Optional[str] = Header(None)):
    """A file as-is; a directory as a streamed zip."""
    check_auth(authorization)
    p = _fs(files.abs_path, path)
    if p.is_file():
        return FileResponse(p, filename=p.name, media_type="application/octet-stream")
    if p.is_dir():
        quoted = urllib.parse.quote(p.name + ".zip")
        return StreamingResponse(files.zip_stream(str(p)), media_type="application/zip",
                                 headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quoted}"})
    raise HTTPException(404, "not found")


class FsPath(BaseModel):
    path: str
    unique: bool = False


class FsMove(BaseModel):
    src: str
    dst: str


@app.post("/box/fs/mkdir")
def fs_mkdir(body: FsPath, authorization: Optional[str] = Header(None)):
    """unique=true returns a fresh name (Folder-1) instead of merging into an existing dir."""
    check_auth(authorization)
    return {"path": str(_fs(files.mkdir, body.path, body.unique))}


@app.post("/box/fs/move")
def fs_move(body: FsMove, authorization: Optional[str] = Header(None)):
    check_auth(authorization)
    return {"path": str(_fs(files.rename, body.src, body.dst))}


@app.post("/box/fs/delete")
def fs_delete(body: FsPath, authorization: Optional[str] = Header(None)):
    """Moves to ~/.helm/trash (purged after a week), never unlinks directly."""
    check_auth(authorization)
    return {"trashed": str(_fs(files.trash, body.path))}


# ---------- WebSocket ----------

@app.websocket("/sessions/{sid}/stream")
async def stream(ws: WebSocket, sid: str):
    token = ws.headers.get("authorization")
    if token and token.startswith("Bearer "):
        token = token[7:]
    elif ws.headers.get("x-helm-route") != "public":
        # Query-param fallback only on wg0; the public Caddy route logs URLs.
        token = ws.query_params.get("token")
    else:
        token = None
    try:
        expected = config.load_token()
    except Exception:
        expected = None
    if not token or not expected or not hmac.compare_digest(token.encode(), expected.encode()):
        await ws.close(code=4401)
        return
    meta = sessionio.read_meta(sid) if SID_RE.match(sid or "") else None
    if not meta:
        await ws.close(code=4404)
        return
    await ws.accept()
    try:
        after = max(0, int(ws.query_params.get("after", 0)))
    except ValueError:
        after = 0

    stop = asyncio.Event()

    async def sender():
        last_sent = after
        last_ping = time.time()
        offset = 0
        loop = asyncio.get_event_loop()
        while not stop.is_set():
            # Byte-offset tail: only new bytes are parsed, and off the event
            # loop, so a multi-MB chat no longer stalls every other request.
            evs, offset = await loop.run_in_executor(
                None, sessionio.tail_events, sid, offset, last_sent)
            for ev in evs:
                await ws.send_text(json.dumps(ev))
                last_sent = ev["seq"]
            if time.time() - last_ping >= 20:
                await ws.send_text(json.dumps({"type": "ping"}))
                last_ping = time.time()
            await asyncio.sleep(0.2)

    async def receiver():
        try:
            while True:
                raw = await ws.receive_text()
                try:
                    msg = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                if msg.get("type") == "message":
                    loop = asyncio.get_event_loop()
                    m = sessionio.read_meta(sid) or meta
                    revived = await loop.run_in_executor(None, _ensure_runner, sid, m)
                    ok = await loop.run_in_executor(
                        None, sessionio.write_inbox, sid, _message_op(msg),
                        30.0 if revived else 12.0)
                    if not ok:
                        sessionio.append_event(sid, {"type": "error", "text": "message not delivered: runner not accepting input"})
                elif msg.get("type") == "dequeue":
                    await asyncio.get_event_loop().run_in_executor(
                        None, sessionio.write_inbox, sid,
                        {"op": "dequeue", "queue_id": msg.get("queue_id")})
                elif msg.get("type") == "interrupt":
                    await asyncio.get_event_loop().run_in_executor(
                        None, sessionio.write_inbox, sid, {"op": "interrupt"})
        except WebSocketDisconnect:
            pass
        finally:
            stop.set()

    send_task = asyncio.create_task(sender())
    recv_task = asyncio.create_task(receiver())
    try:
        await asyncio.wait([send_task, recv_task], return_when=asyncio.FIRST_COMPLETED)
    finally:
        stop.set()
        send_task.cancel()
        recv_task.cancel()
