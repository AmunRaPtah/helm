# Helm protocol (v1)

Helm = native iOS chat client for the CLI harnesses on this box.
Two halves share this contract: `server/` (helmd, Python) and `ios/` (SwiftUI).

## Transport and auth
- helmd listens on `http://10.66.66.1:3340` (wg0 only, never 0.0.0.0).
- Every request carries `Authorization: Bearer <token>`. WebSocket: same header,
  or `?token=` query param as fallback. Token lives in `~/.helm/token` (chmod 600)
  and in Bitwarden item "Helm Token".
- All bodies are JSON. Timestamps are unix seconds (float). IDs are short
  lowercase strings (`[a-z0-9]{8}`).

## Session model
A session = one conversation with one harness, running inside tmux session
`hx-<id>`. The tmux pane runs `helm-runner <id>`, which owns the harness
process(es), appends normalized events to `~/.helm/sessions/<id>/events.jsonl`,
reads user input from `~/.helm/sessions/<id>/inbox` (a FIFO), and prints a
human-readable transcript to the pane so `tmux attach -t hx-<id>` works.
`~/.helm/sessions/<id>/meta.json` holds the Session object.

### Session object
```json
{
  "id": "a1b2c3d4",
  "title": "fix grantfinder classify",     // first user message, truncated 60 chars; renameable
  "harness": "claude",                      // Harness.id
  "profile": null,                          // cx profile name for codex, else null
  "model": null,                            // optional override
  "cwd": "/root/projects/grantfinder",
  "permission": "bypass",                   // bypass | acceptEdits | default | plan
  "state": "idle",                          // starting | idle | running | exited
  "created": 1760800000.0,
  "updated": 1760800100.0,
  "last_seq": 42,                           // highest event seq written
  "native_session_id": "uuid-or-thread-id", // harness's own resume id, once known
  "tmux": "hx-a1b2c3d4"
}
```

### Harness object (`GET /harnesses`)
```json
{ "id": "claude", "name": "Claude Code", "command": "claude",
  "supports_profiles": false, "profiles": [], "available": true,
  "models": [], "default_model": null, "note": null }
```
v1 harness ids: `claude`, `ds`, `cc`, `agy`, `codex`. `codex` has
`supports_profiles: true` and `profiles` = cx profile names (from `cx ls`).
`dsh` is listed with `available: false, note: "phase 2"`.

## Event stream
Events are append-only, numbered by `seq` (1-based, per session). Each line in
events.jsonl and each WebSocket frame is one Event:
```json
{ "seq": 7, "ts": 1760800050.2, "type": "<type>", ...fields }
```
Types:
| type | fields | meaning |
|---|---|---|
| `user` | `text`, `attachments: [path]` | message the user sent |
| `assistant_delta` | `msg_id`, `text` | streaming text chunk; append to bubble `msg_id` |
| `assistant` | `msg_id`, `text` | final full text of bubble `msg_id` (replaces deltas) |
| `thinking` | `msg_id`, `text` | reasoning summary, collapsible |
| `tool_call` | `call_id`, `name`, `input` (string, pretty) | harness invoked a tool |
| `tool_result` | `call_id`, `output` (string, truncated 4000 chars), `is_error` | tool returned |
| `status` | `state` (`running`/`idle`/`exited`), `detail` | turn started/finished, process exit |
| `usage` | `input_tokens`, `output_tokens`, `cost_usd` (nullable) | end-of-turn usage |
| `error` | `text` | harness or runner error, show as red system bubble |
| `system` | `text` | informational (session started, resumed, model name) |

Clients render `assistant_delta` progressively and, when `assistant` with the
same `msg_id` arrives, replace the bubble text. Deltas are optional; a harness
that only emits final `assistant` events is valid.

## REST
| method | path | body | returns |
|---|---|---|---|
| GET | `/health` | | `{"ok":true,"version":"1"}` (no auth) |
| GET | `/harnesses` | | `[Harness]` |
| GET | `/sessions` | | `[Session]` sorted by `updated` desc |
| POST | `/sessions` | `{harness, profile?, model?, cwd?, permission?, text?}` | `Session` (creates tmux session; if `text` given, sends it as first message) |
| GET | `/sessions/{id}` | | `Session` |
| PATCH | `/sessions/{id}` | `{title?}` | `Session` |
| DELETE | `/sessions/{id}` | | `{"ok":true}` (kills tmux, keeps files unless `?purge=1`) |
| GET | `/sessions/{id}/events?after=N&limit=500` | | `[Event]` |
| POST | `/sessions/{id}/messages` | `{text, attachments?: [path]}` | `{"ok":true}` (409 if state=running) |
| POST | `/sessions/{id}/interrupt` | | `{"ok":true}` (SIGINT to current turn) |
| POST | `/sessions/{id}/resume` | | `Session` (restart runner in tmux for an exited session, resuming native_session_id) |
| POST | `/upload` | multipart `file`, form `session_id` | `{"path": "/root/.helm/sessions/<id>/uploads/<name>"}` |
| GET | `/dirs?path=/root/projects` | | `{"path", "entries":[{"name","is_dir"}]}` (dirs only, for cwd picker) |
| GET | `/quota` | | raw JSON from `quota-axi --json` if available, else `{}` |

## WebSocket
`GET /sessions/{id}/stream?after=N` upgrades. Server first replays events with
`seq > after`, then pushes new events live (tail of events.jsonl). Client may
send `{"type":"message","text":...,"attachments":[...]}` or
`{"type":"interrupt"}` over the socket as an alternative to REST. Server sends
`{"type":"ping"}` every 20s. Client reconnects with `after=<last seq seen>`.

## Harness adapters (runner side)
- **claude / ds / cc**: one long-lived process:
  `<cmd> -p --input-format stream-json --output-format stream-json --verbose
  --include-partial-messages --permission-mode <perm> [--model M] [--resume ID]`.
  `bypass` maps to `bypassPermissions`. Each user message = one NDJSON line
  `{"type":"user","message":{"role":"user","content":[{"type":"text","text":...}]}}`.
  `session_id` from the `system/init` event becomes `native_session_id`.
- **agy**: same NDJSON pattern with `-p --input-format stream-json
  --output-format stream-json`; `bypass` -> `--dangerously-skip-permissions`;
  resume via `--conversation ID`.
- **codex**: one process per turn. First turn `codex exec --json ...`, later
  turns `codex exec resume <thread_id> --json ...`, with `CODEX_HOME` from
  `cx env <profile>` when a profile is chosen. thread id -> `native_session_id`.
- Attachments: images are passed as the harness supports them (claude: base64
  image content blocks; codex: `-i path`); other files are referenced by path in
  the message text.
