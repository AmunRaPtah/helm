"""Per-harness command building and NDJSON event parsing.

Verified against real CLI output on this box (2026-10-18):
- claude (-p --input-format stream-json --output-format stream-json
  --verbose --include-partial-messages --permission-mode <mode>): flat
  {"type": "system"/"assistant"/"user"/"stream_event"/"result", ...}.
  ds/cc are wrapper scripts around the same `claude` binary -> identical
  shapes, just different env vars baked in by the wrapper.
- codex exec --json: {"type":"thread.started","thread_id":...},
  {"type":"turn.started"}, {"type":"item.completed","item":{...}},
  {"type":"turn.completed","usage":{...}}. No partial deltas.
- agy (--input-format stream-json --output-format stream-json, NO -p/--print:
  passing -p alongside --input-format stream-json errors out, print mode is
  implied by --input-format): {"event":"<name>", "<name>": {...}} envelope,
  but note conversation_id is TOP-LEVEL on the init record, not nested:
  {"event":"init","conversation_id":"...","init":{"cwd":...,"tools":[...],
  "permission_mode":"always-proceed"}}. Input lines must be
  {"event":"user","message":{"role":"user","content":[{"type":"text","text":...}]}}
  (claude-shaped "message", NOT nested under a "user" key - confirmed by
  reproducing both "missing event field" and "missing message field" errors
  until this exact shape was accepted). step_update records look like
  {"event":"step_update","step_update":{"conversation_id":...,"step_index":
  0,"state":"DONE","step_type":"user_input"/"error_message"/...}}; the box's
  agy account is quota-exhausted (429 RESOURCE_EXHAUSTED) so a successful
  turn's assistant-bearing step_update shape (where real text lives) was
  never observed - the parsing below is best-effort for that one case and
  falls back to a visible `system` debug event rather than silently
  dropping content.
"""
import base64
import json
import mimetypes
import os
import shutil
from pathlib import Path

from . import config

CODEX_BIN = shutil.which("codex") or os.path.expanduser(
    "~/.nvm/versions/node/v24.18.0/bin/codex")

PERMISSION_MAP_CLAUDE = {
    "bypass": "bypassPermissions",
    "acceptEdits": "acceptEdits",
    "default": "default",
    "plan": "plan",
}


def _image_block(path):
    mt, _ = mimetypes.guess_type(path)
    mt = mt or "application/octet-stream"
    with open(path, "rb") as f:
        data = base64.b64encode(f.read()).decode()
    return {"type": "image", "source": {"type": "base64", "media_type": mt, "data": data}}


def _is_image(path):
    mt, _ = mimetypes.guess_type(path)
    return bool(mt and mt.startswith("image/"))


# ---------------------------------------------------------------- claude/ds/cc

# Inside tmux the nvm claude binary precedes /usr/local/bin on PATH, which skips
# the wrapper that injects the pinned OAuth token, and auth then fails.
CLAUDE_WRAPPER = "/usr/local/bin/claude"

# Stream-json flags every claude-family harness needs. The burst (glm/dsv) and
# sukuna launchers all end in `exec claude ... "$@"` (claude-burst via
# session.py), so appending these flags to the launcher makes it emit the same
# NDJSON the plain claude harness does, so one parser (`claude_parse`) covers all.
_STREAM_FLAGS = ["-p", "--input-format", "stream-json", "--output-format",
                 "stream-json", "--verbose", "--include-partial-messages"]

# Harnesses that are a launcher wrapping claude on a GPU-burst / alt backend.
# Value: (launcher path, extra prefix args the launcher consumes before the
# stream flags). The burst launchers already bake in model + permissions
# (claude-burst runs bypass-free but we add the mode; sukuna adds
# --dangerously-skip-permissions itself).
BURST_LAUNCHERS = {
    "glm": ("/root/.local/bin/glm", ["--max-hours", "6"]),
    "dsv": ("/root/.local/bin/dsv", ["--max-hours", "6"]),
}
SUKUNA_LAUNCHER = "/root/.local/bin/sukuna"


def _sandbox_env():
    return {"IS_SANDBOX": "1"} if os.geteuid() == 0 else {}


def claude_cmd(meta):
    h = meta["harness"]

    if h in BURST_LAUNCHERS:
        launcher, prefix = BURST_LAUNCHERS[h]
        cmd = [launcher] + prefix + _STREAM_FLAGS
        cmd += ["--permission-mode",
                PERMISSION_MAP_CLAUDE.get(meta["permission"], "bypassPermissions")]
        if meta.get("native_session_id"):
            cmd += ["--resume", meta["native_session_id"]]
        # Burst models are fixed by the launcher; ignore any meta["model"].
        return cmd, _sandbox_env()

    if h == "sukuna":
        # sukuna already exec's claude with --dangerously-skip-permissions and
        # --append-system-prompt; just hand it the stream flags.
        cmd = [SUKUNA_LAUNCHER] + _STREAM_FLAGS
        if meta.get("native_session_id"):
            cmd += ["--resume", meta["native_session_id"]]
        return cmd, _sandbox_env()

    exe = meta["harness"]
    if exe == "claude" and os.access(CLAUDE_WRAPPER, os.X_OK):
        exe = CLAUDE_WRAPPER
    cmd = [exe] + _STREAM_FLAGS + [
        "--permission-mode",
        PERMISSION_MAP_CLAUDE.get(meta["permission"], "bypassPermissions")]
    if meta.get("model"):
        cmd += ["--model", meta["model"]]
    if meta.get("native_session_id"):
        cmd += ["--resume", meta["native_session_id"]]
    # claude refuses bypassPermissions as root unless IS_SANDBOX is set; don't
    # rely on the tmux server happening to inherit it.
    return cmd, _sandbox_env()


def claude_input_line(text, attachments):
    content = [{"type": "text", "text": text}]
    for a in attachments or []:
        if _is_image(a):
            content.append(_image_block(a))
        else:
            content[0]["text"] += f"\n[attached file: {a}]"
    return json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"


def claude_parse(obj):
    """Return list of normalized event dicts (no seq/ts) and an optional
    native_session_id update, from one raw NDJSON line of claude/ds/cc."""
    events = []
    native_id = None
    t = obj.get("type")
    if t == "system" and obj.get("subtype") == "init":
        native_id = obj.get("session_id")
        events.append({"type": "system", "text": f"session started (model={obj.get('model') or 'default'})"})
        if obj.get("slash_commands"):
            events.append({"type": "_meta", "fields": {"commands": obj["slash_commands"]}})
    elif t == "system" and obj.get("subtype", "").startswith("hook_"):
        pass  # local plugin noise, not protocol
    elif t == "stream_event":
        ev = obj.get("event", {})
        if ev.get("type") == "content_block_delta":
            delta = ev.get("delta", {})
            if delta.get("type") == "text_delta" and delta.get("text"):
                msg_id = obj.get("message_id") or obj.get("parent_tool_use_id") or "stream"
                events.append({"type": "assistant_delta", "msg_id": msg_id, "text": delta["text"]})
    elif t == "assistant":
        msg = obj.get("message", {})
        msg_id = msg.get("id", "?")
        text_parts = []
        for block in msg.get("content", []) or []:
            if block.get("type") == "text":
                text_parts.append(block.get("text", ""))
            elif block.get("type") == "tool_use":
                events.append({"type": "tool_call", "call_id": block.get("id", "?"),
                                "name": block.get("name", "?"),
                                "input": json.dumps(block.get("input", {}), indent=1)})
        if obj.get("error"):
            events.append({"type": "error", "text": "".join(text_parts) or obj["error"]})
        elif text_parts:
            events.append({"type": "assistant", "msg_id": msg_id, "text": "".join(text_parts)})
    elif t == "user":
        msg = obj.get("message", {})
        for block in msg.get("content", []) or []:
            if block.get("type") == "tool_result":
                out = block.get("content")
                if isinstance(out, list):
                    out = "".join(b.get("text", "") for b in out if isinstance(b, dict))
                out = str(out or "")[:4000]
                events.append({"type": "tool_result", "call_id": block.get("tool_use_id", "?"),
                                "output": out, "is_error": bool(block.get("is_error"))})
    elif t == "result":
        usage = obj.get("usage", {}) or {}
        events.append({"type": "usage",
                        "input_tokens": usage.get("input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0),
                        "cost_usd": obj.get("total_cost_usd")})
        if obj.get("is_error"):
            events.append({"type": "error", "text": obj.get("result") or "turn errored"})
        elif isinstance(obj.get("result"), str):
            events.append({"type": "_result_text", "text": obj["result"]})
    return events, native_id


# ------------------------------------------------------------ slash commands

# Before a claude session's first turn there is no init record yet, so fall
# back to the list the last session of the same harness reported.
CLAUDE_BUILTINS = ["compact", "context", "cost", "init", "review", "security-review"]


def _commands_cache(harness):
    return config.HELM_HOME / f"commands-{harness}.json"


def save_commands(harness, commands):
    try:
        _commands_cache(harness).write_text(json.dumps(commands))
    except OSError:
        pass


def known_commands(meta):
    if meta["harness"] not in LONG_LIVED or meta["harness"] == "agy":
        return []
    if meta.get("commands"):
        return meta["commands"]
    try:
        return json.loads(_commands_cache(meta["harness"]).read_text())
    except (OSError, ValueError):
        pass
    skills = Path.home() / ".claude" / "skills"
    names = sorted(p.name for p in skills.iterdir() if (p / "SKILL.md").exists()) if skills.is_dir() else []
    return CLAUDE_BUILTINS + names


# --------------------------------------------------------------------- agy

def agy_cmd(meta):
    # NOTE: -p/--print must NOT be passed at all when --input-format
    # stream-json is set: agy errors with "a prompt given on the command
    # line would be ignored" / "flag needs an argument: -p" either way.
    # Print mode is implied by --input-format stream-json alone.
    cmd = [meta["harness"], "--input-format", "stream-json", "--output-format", "stream-json"]
    if meta["permission"] == "bypass":
        cmd.append("--dangerously-skip-permissions")
    if meta.get("model"):
        cmd += ["--model", meta["model"]]
    if meta.get("native_session_id"):
        cmd += ["--conversation", meta["native_session_id"]]
    return cmd, {}


def agy_input_line(text, attachments):
    for a in attachments or []:
        text += f"\n[attached file: {a}]"
    # Confirmed shape (2026-10-18): claude-style "message" object at the
    # top level, NOT nested under a "user" key. {"event":"user","user":...}
    # fails with 'missing the "message" field'.
    return json.dumps({"event": "user",
                        "message": {"role": "user", "content": [{"type": "text", "text": text}]}}) + "\n"


def agy_parse(obj):
    events = []
    native_id = None
    ev = obj.get("event")
    if ev == "init":
        # conversation_id is top-level on the init record, not nested
        # inside "init" (confirmed 2026-10-18).
        native_id = obj.get("conversation_id")
        init = obj.get("init", {})
        events.append({"type": "system", "text": f"session started (model={init.get('model') or 'default'})"})
    elif ev == "step_update":
        su = obj.get("step_update", {})
        step_type = su.get("step_type")
        text = su.get("text") or su.get("message") or su.get("content")
        if step_type in ("assistant_message", "text", "text_response") and text:
            events.append({"type": "assistant", "msg_id": str(su.get("step_index", "?")), "text": text})
        elif step_type in ("tool_call",) and text:
            events.append({"type": "tool_call", "call_id": str(su.get("step_index", "?")),
                            "name": su.get("name", "tool"), "input": text})
        elif step_type in ("tool_result",) and text:
            events.append({"type": "tool_result", "call_id": str(su.get("step_index", "?")),
                            "output": text[:4000], "is_error": False})
        elif step_type == "error_message":
            # confirmed shape (quota-exhaustion run): the human-readable
            # error actually comes on a separate top-level "error:" stderr
            # line and the final "result" record, not inside step_update
            # itself (no text field observed here) - surface what we have.
            events.append({"type": "system", "text": f"[error_message step] {json.dumps(su)}"[:1000]})
        elif step_type not in ("user_input",) and text:
            # unrecognized but has content: surface rather than drop
            events.append({"type": "system", "text": f"[{step_type}] {text}"[:1000]})
    elif ev == "result":
        res = obj.get("result", {})
        usage = res.get("usage", {}) or {}
        events.append({"type": "usage", "input_tokens": usage.get("input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0), "cost_usd": None})
        if res.get("status") == "ERROR":
            events.append({"type": "error", "text": res.get("error") or "agy turn errored"})
        elif res.get("response"):
            events.append({"type": "assistant", "msg_id": "result", "text": res["response"]})
    return events, native_id


# ------------------------------------------------------------------- codex

def codex_cmd(meta, text, attachments):
    env = {}
    if meta.get("profile"):
        env["CODEX_HOME"] = f"/root/.codex-profiles/{meta['profile']}"
    cmd = [CODEX_BIN, "exec"]
    if meta.get("native_session_id"):
        cmd += ["resume", meta["native_session_id"]]
    cmd += ["--json", "--skip-git-repo-check", "--dangerously-bypass-approvals-and-sandbox"]
    if not meta.get("native_session_id"):
        cmd += ["-C", meta["cwd"]]
    if meta.get("model"):
        cmd += ["-m", meta["model"]]
    images = [a for a in (attachments or []) if _is_image(a)]
    for img in images:
        cmd += ["-i", img]
    non_images = [a for a in (attachments or []) if not _is_image(a)]
    for a in non_images:
        text += f"\n[attached file: {a}]"
    cmd.append(text)
    return cmd, env


def codex_parse(obj):
    events = []
    native_id = None
    t = obj.get("type")
    if t == "thread.started":
        native_id = obj.get("thread_id")
        events.append({"type": "system", "text": "session started"})
    elif t == "turn.started":
        events.append({"type": "status", "state": "running", "detail": None})
    elif t == "item.completed":
        item = obj.get("item", {})
        it = item.get("type")
        if it == "agent_message":
            events.append({"type": "assistant", "msg_id": item.get("id", "?"), "text": item.get("text", "")})
        elif it == "reasoning":
            events.append({"type": "thinking", "msg_id": item.get("id", "?"), "text": item.get("text", "")})
        else:
            # command_execution / tool-like items: codex emits one
            # completed record per tool, so synthesize a call+result pair.
            call_id = item.get("id", "?")
            cmdtext = item.get("command") or item.get("text") or json.dumps(item)[:500]
            events.append({"type": "tool_call", "call_id": call_id, "name": it or "tool", "input": str(cmdtext)})
            out = item.get("aggregated_output") or item.get("output") or ""
            events.append({"type": "tool_result", "call_id": call_id, "output": str(out)[:4000],
                            "is_error": bool(item.get("exit_code"))})
    elif t == "turn.completed":
        usage = obj.get("usage", {}) or {}
        events.append({"type": "usage", "input_tokens": usage.get("input_tokens", 0),
                        "output_tokens": usage.get("output_tokens", 0), "cost_usd": None})
    elif t == "turn.failed":
        events.append({"type": "error", "text": json.dumps(obj.get("error", obj))[:2000]})
    else:
        events.append({"type": "system", "text": f"[codex:{t}] " + json.dumps(obj)[:500]})
    return events, native_id


LONG_LIVED = {"claude", "ds", "cc", "agy", "glm", "dsv", "sukuna"}
