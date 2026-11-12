// Helm for Windows: UI. All network goes through the Rust side (invoke),
// which holds the decrypted credentials only while unlocked.
"use strict";

const T = window.__TAURI__;
const invoke = T.core.invoke;
const $ = (id) => document.getElementById(id);
const md = window.renderMarkdown;
const esc = window.escapeHtml;
const U = window.HelmUtil;

const api = (method, path, body = null, timeoutSecs = null) => invoke("api", { method, path, body, timeoutSecs });
const enc = encodeURIComponent;

const HARNESS = {
  claude: ["#D97757", "Claude"], codex: ["#10A37F", "Codex"], ds: ["#4D6BFE", "DeepSeek"],
  cc: ["#A970FF", "Compound"], agy: ["#F4B400", "Antigravity"], dsh: ["#38BDF8", "DSH"],
  glm: ["#22C55E", "GLM"], dsv: ["#0EA5E9", "DeepSeek V4"], sukuna: ["#DC2626", "Sukuna"],
  venice: ["#F97316", "Venice"], api: ["#64748B", "API"],
};
const hstyle = (id) => HARNESS[(id || "").toLowerCase()] || ["#8A93A0", id || "?"];

function h(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "html") e.innerHTML = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "style" && typeof v === "object") Object.assign(e.style, v);
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) e.append(kid.nodeType ? kid : String(kid));
  return e;
}

function ago(ts) {
  if (!ts) return "";
  const s = Date.now() / 1000 - ts;
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  if (s < 86400 * 7) return `${Math.floor(s / 86400)}d`;
  return new Date(ts * 1000).toLocaleDateString();
}
const kfmt = (n) => (n == null ? "?" : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
const bytes = (n) => {
  if (n == null) return "";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
};
const cid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

// ---------- toasts and modals ----------
function toast(text, kind = "") {
  const t = h("div", { class: `toast ${kind}` }, text);
  $("toasts").append(t);
  setTimeout(() => t.classList.add("out"), 3200);
  setTimeout(() => t.remove(), 3700);
}
const fail = (e) => toast(String(e && e.message ? e.message : e), "bad");

const openModals = new Set(); // close functions, so locking dismisses them
function modal(title, body, buttons) {
  return new Promise((resolve) => {
    let busy = false;
    const close = (v) => {
      openModals.delete(close);
      root.remove();
      document.removeEventListener("keydown", onKey, true);
      resolve(v);
    };
    const onKey = (e) => { if (e.key === "Escape" && !busy) { e.stopPropagation(); close(null); } };
    const btns = buttons.map((b) => h("button", { class: `btn ${b.kind || "ghost"}`, onclick: async () => {
      // An async action (e.g. "Start" creating a session) runs once: a second
      // click while it is in flight used to create a duplicate session.
      if (busy) return;
      if (!b.value) { close(b.result); return; }
      busy = true;
      btns.forEach((x) => (x.disabled = true));
      let v;
      try { v = await b.value(); } finally { busy = false; btns.forEach((x) => (x.disabled = false)); }
      if (v !== undefined && openModals.has(close)) close(v);
    } }, b.label));
    const root = h("div", { class: "modal-back", onmousedown: (e) => e.target === root && !busy && close(null) },
      h("div", { class: "modal" },
        h("h3", {}, title),
        h("div", { class: "modal-body" }, body),
        h("div", { class: "modal-foot" }, btns)));
    openModals.add(close);
    document.addEventListener("keydown", onKey, true);
    $("modal-root").append(root);
    const f = root.querySelector("input,textarea,select");
    if (f) setTimeout(() => f.focus(), 30);
  });
}
async function ask(title, label, value = "") {
  const inp = h("input", { value, class: "wide" });
  inp.addEventListener("keydown", (e) => { if (e.key === "Enter") inp.closest(".modal").querySelector(".modal-foot .primary").click(); });
  return modal(title, h("label", { class: "field" }, label, inp), [
    { label: "Cancel", result: null },
    { label: "OK", kind: "primary", result: undefined, value: () => inp.value },
  ]);
}
const confirmBox = (title, text, label = "Delete") =>
  modal(title, h("p", {}, text), [{ label: "Cancel", result: false }, { label, kind: "danger", result: true }]);

// ---------- version ----------
T.app.getVersion().then((v) => document.querySelectorAll("[data-version]").forEach((e) => (e.textContent = `v${v}`))).catch(() => {});

// ---------- lock ----------
let unlocked = false;
let idleTimer = null;
const IDLE_LOCK_MS = 30 * 60 * 1000;

$("lock-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const pw = $("lock-pw").value;
  if (!pw) return;
  $("lock-btn").disabled = true;
  $("lock-btn").textContent = "Unlocking…";
  $("lock-err").textContent = "";
  try {
    await invoke("unlock", { password: pw });
    $("lock-pw").value = "";
    unlocked = true;
    $("lock").classList.add("hidden");
    $("app").classList.remove("hidden");
    bumpIdle();
    startApp();
  } catch (err) {
    $("lock-err").textContent = String(err);
    $("lock-pw").select();
  } finally {
    $("lock-btn").disabled = false;
    $("lock-btn").textContent = "Unlock";
  }
});

async function lockNow() {
  if (!unlocked) return;
  unlocked = false;
  closeChat();
  stopTimers();
  await invoke("lock").catch(() => {});
  [...openModals].forEach((close) => close(null));
  $("modal-root").innerHTML = "";
  $("app").classList.add("hidden");
  $("lock").classList.remove("hidden");
  $("lock-pw").focus();
}
$("lock-now").onclick = lockNow;
function bumpIdle() {
  clearTimeout(idleTimer);
  if (unlocked) idleTimer = setTimeout(lockNow, IDLE_LOCK_MS);
}
["mousedown", "keydown", "wheel"].forEach((ev) => document.addEventListener(ev, bumpIdle, { passive: true }));

// ---------- timers ----------
const timers = new Set();
function every(ms, fn) { const t = setInterval(fn, ms); timers.add(t); return t; }
function stopTimers() { timers.forEach(clearInterval); timers.clear(); }

// ---------- navigation ----------
let view = "chats";
document.querySelectorAll(".nav-btn").forEach((b) => (b.onclick = () => showView(b.dataset.view)));
function showView(v) {
  view = v;
  document.querySelectorAll(".nav-btn").forEach((b) => b.classList.toggle("active", b.dataset.view === v));
  for (const name of ["chats", "box", "files"]) $(`view-${name}`).classList.toggle("hidden", name !== v);
  $("side-chats").classList.toggle("dim", v !== "chats");
  if (v === "box") showBoxTab(boxTab);
  if (v === "files") listFiles(filesPath);
}

function startApp() {
  showView("chats");
  refreshSessions();
  every(5000, () => unlocked && refreshSessions());
}

// ---------- sessions ----------
let sessions = [];
let harnesses = null;

async function refreshSessions() {
  try {
    sessions = await api("GET", "/sessions");
    setConn(true);
    renderSessions();
    if (chat) {
      const s = sessions.find((x) => x.id === chat.id);
      if (s) { chat.session = { ...chat.session, ...s }; renderChatHead(); }
    }
  } catch (e) {
    setConn(false, e);
  }
}
function setConn(ok, err) {
  const c = $("conn");
  c.textContent = ok ? "connected" : "offline";
  c.className = `conn ${ok ? "ok" : "bad"}`;
  c.title = ok ? "" : String(err || "");
}
$("session-filter").addEventListener("input", renderSessions);

function renderSessions() {
  const q = $("session-filter").value.trim().toLowerCase();
  const list = $("session-list");
  list.replaceChildren(...sessions
    .filter((s) => !q || `${s.title} ${s.cwd} ${s.harness}`.toLowerCase().includes(q))
    .map((s) => {
      const [color, name] = hstyle(s.harness);
      return h("li", { class: `session ${chat && chat.id === s.id ? "active" : ""}`, onclick: () => openChat(s) },
        h("span", { class: "dot", style: { background: color } }),
        h("div", { class: "session-text" },
          h("div", { class: "session-title" }, s.title || "(untitled)"),
          h("div", { class: "session-meta" }, `${name} · ${(s.cwd || "").replace(/^\/root\/?/, "~/")}`)),
        h("div", { class: "session-right" },
          h("span", { class: "small muted" }, ago(s.updated)),
          h("span", { class: `pill ${s.state}` }, s.state === "running" ? "●" : s.state === "exited" ? "exited" : "")));
    }));
}

// ---------- chat ----------
let chat = null; // current chat state
const wsBuffer = new Map(); // frames that arrive before ws_open resolves

function newChatState(s) {
  return {
    id: s.id, session: s, lastSeq: 0, items: [], byMsg: new Map(), byCall: new Map(),
    pending: [], attachments: [], streamId: null, gen: 0, backoff: 1000, closed: false,
    dirty: new Set(), following: true, lastTop: 0, commands: null,
  };
}

function openChat(s) {
  if (chat && chat.id === s.id) return;
  closeChat();
  chat = newChatState(s);
  showView("chats");
  $("chat-empty").classList.add("hidden");
  $("chat").classList.remove("hidden");
  $("items").replaceChildren();
  $("pending").replaceChildren();
  $("attach-chips").replaceChildren();
  renderChatHead();
  renderSessions();
  connect();
  api("GET", `/sessions/${s.id}/commands`).then((r) => chat && chat.id === s.id && (chat.commands = r.commands || [])).catch(() => {});
  $("input").focus();
}

function closeChat() {
  if (!chat) return;
  chat.closed = true;
  if (chat.streamId) invoke("ws_close", { id: chat.streamId }).catch(() => {});
  clearTimeout(chat.retry);
  chat = null;
  $("chat").classList.add("hidden");
  $("chat-empty").classList.remove("hidden");
}

function connect() {
  const c = chat;
  if (!c || c.closed || !unlocked) return;
  const gen = ++c.gen;
  c.streamId = null;
  invoke("ws_open", { sessionId: c.id, after: c.lastSeq })
    .then((sid) => {
      if (c.closed || gen !== c.gen) { invoke("ws_close", { id: sid }).catch(() => {}); return; }
      c.streamId = sid;
      const early = wsBuffer.get(sid) || [];
      wsBuffer.clear(); // frames from older, closed streams are never wanted
      early.forEach(onFrame);
    })
    .catch((e) => { setConn(false, e); retryLater(c); });
}
function retryLater(c) {
  if (c.closed || !unlocked) return;
  clearTimeout(c.retry);
  c.retry = setTimeout(connect, c.backoff);
  c.backoff = Math.min(c.backoff * 2, 15000);
}

T.event.listen("ws", (e) => {
  const p = e.payload;
  if (!chat || chat.closed) return;
  if (chat.streamId == null) {
    if (!wsBuffer.has(p.id)) wsBuffer.set(p.id, []);
    wsBuffer.get(p.id).push(p);
    return;
  }
  if (p.id === chat.streamId) onFrame(p);
});

function onFrame(p) {
  const c = chat;
  if (!c) return;
  if (p.closed) {
    c.streamId = null;
    retryLater(c);
    return;
  }
  c.backoff = 1000;
  let ev;
  try { ev = JSON.parse(p.data); } catch { return; }
  if (ev.type === "ping" || ev.seq == null) return;
  apply(c, ev);
  schedule();
}

function addItem(c, item) {
  c.items.push(item);
  c.dirty.add(item);
  return item;
}

function apply(c, ev) {
  if (ev.seq <= c.lastSeq) return;
  c.lastSeq = ev.seq;
  switch (ev.type) {
    case "user": {
      c.pending = c.pending.filter((p) => !((ev.client_id && p.client_id === ev.client_id) || (ev.queue_id && p.queue_id === ev.queue_id)));
      c.pendingDirty = true;
      addItem(c, { kind: "user", text: ev.text || "", attachments: ev.attachments || [], ts: ev.ts });
      break;
    }
    case "queued": {
      let p = c.pending.find((x) => x.client_id && x.client_id === ev.client_id);
      if (!p) { p = { client_id: ev.client_id, text: ev.text || "" }; c.pending.push(p); }
      p.queue_id = ev.queue_id;
      p.state = "queued";
      c.pendingDirty = true;
      break;
    }
    case "dequeued":
      c.pending = c.pending.filter((p) => p.queue_id !== ev.queue_id && !(ev.client_id && p.client_id === ev.client_id));
      c.pendingDirty = true;
      break;
    case "assistant_delta": {
      let it = c.byMsg.get(ev.msg_id);
      if (!it) { it = addItem(c, { kind: "assistant", text: "" }); c.byMsg.set(ev.msg_id, it); }
      it.text += ev.text || "";
      c.dirty.add(it);
      break;
    }
    case "assistant":
    case "thinking": {
      const key = `${ev.type}:${ev.msg_id}`;
      let it = c.byMsg.get(ev.type === "assistant" ? ev.msg_id : key);
      if (!it) {
        it = addItem(c, { kind: ev.type, text: "" });
        c.byMsg.set(ev.type === "assistant" ? ev.msg_id : key, it);
      }
      it.text = ev.text || "";
      c.dirty.add(it);
      break;
    }
    case "tool_call": {
      const it = addItem(c, { kind: "tool", name: ev.name, input: ev.input || "", output: null, isError: false });
      c.byCall.set(ev.call_id, it);
      break;
    }
    case "tool_result": {
      let it = c.byCall.get(ev.call_id);
      if (!it) it = addItem(c, { kind: "tool", name: "tool", input: "", output: null });
      it.output = ev.output || "";
      it.isError = !!ev.is_error;
      c.dirty.add(it);
      break;
    }
    case "status":
      c.session.state = ev.state;
      if (ev.state === "exited") addItem(c, { kind: "line", cls: "exited", text: `Session exited${ev.detail ? `: ${ev.detail}` : ""}` });
      renderChatHead();
      break;
    case "usage": {
      const cost = ev.cost_usd != null ? ` · $${Number(ev.cost_usd).toFixed(4)}` : "";
      addItem(c, { kind: "line", cls: "usage", text: `${kfmt(ev.input_tokens)} in · ${kfmt(ev.output_tokens)} out${cost}` });
      break;
    }
    case "error":
      addItem(c, { kind: "line", cls: "error", text: ev.text || "error" });
      break;
    case "system":
      addItem(c, { kind: "line", cls: "system", text: ev.text || "" });
      break;
  }
}

// Batched rendering, once per frame.
let rafPending = false;
function schedule() {
  if (rafPending) return;
  rafPending = true;
  requestAnimationFrame(flush);
}
function flush() {
  rafPending = false;
  const c = chat;
  if (!c) return;
  const box = $("items");
  for (const it of c.dirty) {
    const fresh = renderItem(it);
    if (it.el && it.el.parentNode) {
      // Keep a tool card or thinking block open if the user expanded it.
      const wasOpen = it.el.querySelector("details")?.open;
      if (wasOpen) fresh.querySelector("details")?.setAttribute("open", "");
      it.el.replaceWith(fresh);
    } else box.append(fresh);
    it.el = fresh;
  }
  c.dirty.clear();
  if (c.pendingDirty) { renderPending(); c.pendingDirty = false; }
  renderLiveState();
  if (c.following) scrollToEnd();
}

function renderItem(it) {
  switch (it.kind) {
    case "user":
      return h("div", { class: "msg user" },
        h("div", { class: "bubble", html: md(it.text) }),
        it.attachments.length ? h("div", { class: "atts" }, it.attachments.map((a) => h("span", { class: "chip" }, a.split("/").pop()))) : null);
    case "assistant":
      return h("div", { class: "msg assistant" }, h("div", { class: "bubble", html: md(it.text) }));
    case "thinking":
      return h("div", { class: "msg thinking" },
        h("details", {}, h("summary", {}, "Thinking"), h("div", { class: "think-body", html: md(it.text) })));
    case "tool": {
      const status = it.output == null ? "running" : it.isError ? "failed" : "done";
      const first = (it.input || "").split("\n")[0].slice(0, 120);
      return h("div", { class: `msg tool ${status}` },
        h("details", {},
          h("summary", {}, h("span", { class: "tool-name" }, it.name), h("span", { class: "tool-arg mono" }, first), h("span", { class: "tool-state" }, status)),
          it.input ? h("pre", { class: "mono" }, it.input) : null,
          it.output != null ? h("pre", { class: `mono out ${it.isError ? "err" : ""}` }, it.output || "(no output)") : null));
    }
    default:
      return h("div", { class: `line ${it.cls}` }, it.text);
  }
}

function renderPending() {
  const c = chat;
  $("pending").replaceChildren(...c.pending.map((p) =>
    h("div", { class: `msg user pending ${p.state || "sending"}` },
      h("div", { class: "bubble", html: md(p.text) }),
      h("div", { class: "pending-meta" },
        p.state === "failed" ? [
          h("span", { class: "err" }, "Not sent"),
          h("button", { class: "linkbtn", onclick: () => sendPending(p) }, "Retry"),
          h("button", { class: "linkbtn", onclick: () => { c.pending = c.pending.filter((x) => x !== p); renderPending(); } }, "Discard"),
        ] : p.state === "queued" ? [
          h("span", {}, "Queued"),
          h("button", { class: "linkbtn", onclick: () => api("DELETE", `/sessions/${c.id}/queue/${p.queue_id}`).catch(fail) }, "Cancel"),
        ] : h("span", {}, c.session.state === "starting" ? "Reconnecting…" : "Sending…")))));
}

// --- scroll: follow new output only while the reader is at the bottom ---
const tr = $("transcript");
function scrollToEnd() {
  tr.scrollTop = tr.scrollHeight;
  if (chat) chat.lastTop = tr.scrollTop;
}
tr.addEventListener("scroll", () => {
  const c = chat;
  if (!c) return;
  const dist = tr.scrollHeight - tr.scrollTop - tr.clientHeight;
  if (dist <= 24) c.following = true;
  else if (tr.scrollTop < c.lastTop - 1) c.following = false; // user moved up
  c.lastTop = tr.scrollTop;
  $("jump").classList.toggle("hidden", c.following);
}, { passive: true });
$("jump").onclick = () => { if (chat) { chat.following = true; scrollToEnd(); $("jump").classList.add("hidden"); } };

// Links: copy instead of navigating the app window away.
document.addEventListener("click", (e) => {
  const a = e.target.closest("a.link");
  if (a) { e.preventDefault(); navigator.clipboard.writeText(a.dataset.href.replace(/&amp;/g, "&")); toast("Link copied"); return; }
  const cp = e.target.closest("[data-copy]");
  if (cp) {
    navigator.clipboard.writeText(cp.closest(".code").querySelector("code").textContent);
    cp.textContent = "Copied";
    setTimeout(() => (cp.textContent = "Copy"), 1200);
  }
});

function renderChatHead() {
  const c = chat;
  if (!c) return;
  const s = c.session;
  const [color, name] = hstyle(s.harness);
  const b = $("chat-badge");
  b.textContent = name;
  b.style.color = color;
  b.style.borderColor = `${color}55`;
  b.style.background = `${color}1a`;
  $("chat-title").textContent = s.title || "(untitled)";
  $("chat-sub").textContent = [s.cwd, s.model, s.profile, s.permission].filter(Boolean).join(" · ");
  const st = $("chat-state");
  st.textContent = s.state;
  st.className = `state ${s.state}`;
  $("act-interrupt").classList.toggle("hidden", s.state !== "running");
  $("act-resume").classList.toggle("hidden", s.state !== "exited");
  renderLiveState();
}

// Typing dots while a turn runs; "Reconnecting to X…" while helmd revives a
// dead runner (state "starting" until the runner reports idle/running).
let lastLiveState = null;
function renderLiveState() {
  const c = chat;
  const state = c ? c.session.state : null;
  $("typing").classList.toggle("hidden", state !== "running");
  const txt = c ? U.reconnectText(state, hstyle(c.session.harness)[1]) : null;
  const rc = $("reconnect");
  rc.textContent = txt || "";
  rc.classList.toggle("hidden", !txt);
  // Pending bubbles say "Reconnecting…" instead of "Sending…" meanwhile.
  if (c && state !== lastLiveState && c.pending.some((p) => p.state === "sending")) renderPending();
  lastLiveState = state;
}

$("act-interrupt").onclick = () => chat && api("POST", `/sessions/${chat.id}/interrupt`).catch(fail);
$("act-resume").onclick = async () => {
  if (!chat) return;
  try { chat.session = await api("POST", `/sessions/${chat.id}/resume`); renderChatHead(); toast("Resuming…"); } catch (e) { fail(e); }
};
$("act-rename").onclick = async () => {
  if (!chat) return;
  const t = await ask("Rename chat", "Title", chat.session.title || "");
  if (!t || !t.trim()) return;
  try { chat.session = await api("PATCH", `/sessions/${chat.id}`, { title: t.trim() }); renderChatHead(); refreshSessions(); } catch (e) { fail(e); }
};
$("act-delete").onclick = async () => {
  if (!chat) return;
  const s = chat.session;
  // Without ?purge=1 helmd only kills tmux and keeps meta.json, so the chat
  // reappears in the list on the next refresh. Offer both, clearly labelled.
  const how = await modal("Delete this chat?", h("p", {},
    `"Stop" kills tmux session ${s.tmux} but keeps the chat (it can be resumed). `,
    "\"Delete\" also removes its transcript and uploads from the box."), [
    { label: "Cancel", result: null },
    { label: "Stop only", result: "stop" },
    { label: "Delete", kind: "danger", result: "purge" },
  ]);
  if (!how) return;
  try {
    await api("DELETE", `/sessions/${s.id}${how === "purge" ? "?purge=1" : ""}`);
    if (how === "purge") { sessions = sessions.filter((x) => x.id !== s.id); closeChat(); renderSessions(); }
    else toast("Session stopped");
    refreshSessions();
  } catch (e) { fail(e); }
};

// --- composer ---
const input = $("input");
function autosize() { input.style.height = "auto"; input.style.height = `${Math.min(input.scrollHeight, 260)}px`; }
input.addEventListener("input", () => { autosize(); updateSlash(); });
input.addEventListener("keydown", (e) => {
  const sl = $("slash");
  if (!sl.classList.contains("hidden")) {
    const opts = [...sl.children];
    let i = opts.findIndex((o) => o.classList.contains("sel"));
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      i = (i + (e.key === "ArrowDown" ? 1 : -1) + opts.length) % opts.length;
      opts.forEach((o, j) => o.classList.toggle("sel", j === i));
      return;
    }
    const exact = i >= 0 && input.value === `/${opts[i].dataset.cmd}`;
    if (e.key === "Tab" || (e.key === "Enter" && i >= 0 && !exact)) {
      e.preventDefault();
      pickSlash(opts[Math.max(i, 0)].dataset.cmd);
      return;
    }
    if (e.key === "Escape") { sl.classList.add("hidden"); return; }
  }
  if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); send(); }
});
function updateSlash() {
  const sl = $("slash");
  const m = input.value.match(/^\/(\S*)$/);
  const cmds = chat && chat.commands;
  if (!m || !cmds || !cmds.length) { sl.classList.add("hidden"); return; }
  const hits = cmds.filter((c) => c.toLowerCase().startsWith(m[1].toLowerCase())).slice(0, 12);
  if (!hits.length) { sl.classList.add("hidden"); return; }
  sl.replaceChildren(...hits.map((c, j) => h("li", { class: j === 0 ? "sel" : "", "data-cmd": c, onmousedown: (e) => { e.preventDefault(); pickSlash(c); } }, `/${c}`)));
  sl.classList.remove("hidden");
}
function pickSlash(c) { input.value = `/${c} `; $("slash").classList.add("hidden"); input.focus(); autosize(); }

$("send").onclick = send;
async function send() {
  const c = chat;
  if (!c) return;
  const text = input.value.trim();
  if (!text && !c.attachments.length) return;
  if (c.uploading) { toast("Wait for the upload to finish"); return; }
  const p = { client_id: cid(), text, attachments: c.attachments.map((a) => a.path), state: "sending" };
  c.pending.push(p);
  c.attachments = [];
  renderChips();
  input.value = "";
  autosize();
  $("slash").classList.add("hidden");
  c.following = true;
  renderPending();
  scrollToEnd();
  sendPending(p);
}
async function sendPending(p) {
  const c = chat;
  p.state = "sending";
  renderPending();
  try {
    // A dead runner is revived on send: helmd starts it and waits up to 30s
    // for it to take the message, so leave plenty of headroom before calling
    // the send failed.
    const r = await api("POST", `/sessions/${c.id}/messages`, { text: p.text, attachments: p.attachments, client_id: p.client_id }, 120);
    if (r && r.queued && p.state === "sending") p.state = "queued";
    // The stream normally delivers the "starting" status first; if it is
    // reconnecting itself, show the revive from the response instead.
    if (r && r.revived && chat === c && c.session.state === "exited") { c.session.state = "starting"; renderChatHead(); }
  } catch (e) {
    p.state = "failed";
    fail(e);
  }
  if (chat === c) renderPending();
}

// --- attachments ---
function renderChips() {
  const c = chat;
  $("attach-chips").replaceChildren(...(c ? c.attachments : []).map((a) =>
    h("span", { class: "chip" }, a.name, h("button", { class: "x", title: "Remove", onclick: () => { c.attachments = c.attachments.filter((x) => x !== a); renderChips(); } }, "×"))));
}
async function attachPaths(paths) {
  const c = chat;
  if (!c || !paths || !paths.length) return;
  c.uploading = (c.uploading || 0) + 1;
  for (const path of paths) {
    const name = path.split(/[\\/]/).pop();
    const chip = h("span", { class: "chip busy" }, `Uploading ${name}…`);
    $("attach-chips").append(chip);
    try {
      const r = await invoke("upload", { endpoint: "/upload", localPath: path, fields: { session_id: c.id } });
      c.attachments.push({ name, path: r.path });
    } catch (e) { fail(e); }
    chip.remove();
  }
  c.uploading--;
  if (chat === c) renderChips();
}
$("attach").onclick = async () => {
  const picked = await T.dialog.open({ multiple: true, directory: false, title: "Attach files" });
  if (picked) attachPaths(Array.isArray(picked) ? picked : [picked]);
};
T.webview.getCurrentWebview().onDragDropEvent((e) => {
  if (e.payload.type !== "drop" || !unlocked) return;
  if (view === "chats" && chat) attachPaths(e.payload.paths);
  else if (view === "files") uploadToFolder(e.payload.paths);
});

// ---------- new chat ----------
$("new-chat").onclick = newChat;
async function newChat() {
  try { harnesses = harnesses || (await api("GET", "/harnesses")); } catch (e) { fail(e); return; }
  const avail = harnesses.filter((x) => x.available);
  const sel = h("select", {}, avail.map((x) => h("option", { value: x.id }, x.name)));
  const profile = h("select", {});
  const model = h("select", {});
  const perm = h("select", {}, ["bypass", "acceptEdits", "default", "plan"].map((p) => h("option", { value: p }, p)));
  const cwd = h("input", { value: "/root/projects", class: "mono wide", spellcheck: "false" });
  const dirs = h("ul", { class: "dirs hidden" });
  const text = h("textarea", { rows: 4, placeholder: "First message (optional)" });
  const profRow = h("label", { class: "field" }, "Account", profile);
  const modelRow = h("label", { class: "field" }, "Model", model);
  const sync = () => {
    const hx = avail.find((x) => x.id === sel.value) || {};
    profRow.classList.toggle("hidden", !hx.supports_profiles);
    profile.replaceChildren(h("option", { value: "" }, "default"), ...(hx.profiles || []).map((p) => h("option", { value: p }, p)));
    modelRow.classList.toggle("hidden", !(hx.models && hx.models.length));
    model.replaceChildren(h("option", { value: "" }, `default${hx.default_model ? ` (${hx.default_model})` : ""}`), ...(hx.models || []).map((m) => h("option", { value: m }, m)));
  };
  sel.onchange = sync;
  sync();
  const browse = async (path) => {
    try {
      const r = await api("GET", `/dirs?path=${enc(path)}`);
      cwd.value = r.path;
      const up = r.path.replace(/\/[^/]+\/?$/, "") || "/";
      dirs.replaceChildren(
        h("li", { class: "dir up", onclick: () => browse(up) }, "↑ .."),
        ...r.entries.filter((e) => e.is_dir).map((e) => h("li", { class: "dir", onclick: () => browse(`${r.path.replace(/\/$/, "")}/${e.name}`) }, e.name)));
      dirs.classList.remove("hidden");
    } catch (e) { fail(e); }
  };
  const body = h("div", { class: "form" },
    h("label", { class: "field" }, "Harness", sel), profRow, modelRow,
    h("label", { class: "field" }, "Folder", h("div", { class: "row" }, cwd, h("button", { class: "btn ghost", type: "button", onclick: () => browse(cwd.value) }, "Browse"))),
    dirs,
    h("label", { class: "field" }, "Permissions", perm),
    h("label", { class: "field" }, "Message", text));
  const res = await modal("New chat", body, [
    { label: "Cancel", result: null },
    { label: "Start", kind: "primary", value: async () => {
      try {
        return await api("POST", "/sessions", {
          harness: sel.value, profile: profile.value || null, model: model.value || null,
          cwd: cwd.value.trim() || null, permission: perm.value, text: text.value.trim() || null,
        }, 90);
      } catch (e) { fail(e); return undefined; }
    } },
  ]);
  if (res && res.id) { await refreshSessions(); openChat(res); }
}

// ---------- Box ----------
let boxTab = "system";
document.querySelectorAll("#box-tabs .tab").forEach((b) => (b.onclick = () => showBoxTab(b.dataset.tab)));
let boxTimer = null;
function showBoxTab(tab) {
  boxTab = tab;
  document.querySelectorAll("#box-tabs .tab").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
  clearInterval(boxTimer);
  timers.delete(boxTimer);
  const body = $("box-body");
  body.replaceChildren();
  ({ system: boxSystem, tmux: boxTmux, services: boxServices, burst: boxBurst, reaper: boxReaper, shell: boxShell })[tab](body);
}
const boxLive = (tab) => unlocked && view === "box" && boxTab === tab;

function boxSystem(body) {
  const grid = h("div", { class: "cards" });
  body.append(grid);
  const load = async () => {
    try {
      const s = await api("GET", "/box/system");
      const up = s.uptime_seconds;
      const card = (label, value, sub, pct) => h("div", { class: "card" },
        h("div", { class: "card-label" }, label), h("div", { class: "card-value" }, value),
        sub ? h("div", { class: "small muted" }, sub) : null,
        pct != null ? h("div", { class: "bar" }, h("i", { style: { width: `${Math.min(100, pct)}%`, background: pct > 85 ? "var(--red)" : pct > 70 ? "var(--amber)" : "var(--lime)" } })) : null);
      grid.replaceChildren(
        card("Host", s.hostname, `up ${Math.floor(up / 86400)}d ${Math.floor((up % 86400) / 3600)}h`),
        card("Load", s.loadavg.map((x) => x.toFixed(2)).join("  "), `${s.cpus} CPUs`, (s.loadavg[0] / s.cpus) * 100),
        card("Memory", `${(s.mem_used_mb / 1024).toFixed(1)} / ${(s.mem_total_mb / 1024).toFixed(1)} GB`, `${(s.mem_available_mb / 1024).toFixed(1)} GB available`, (s.mem_used_mb / s.mem_total_mb) * 100),
        card("Swap", `${(s.swap_used_mb / 1024).toFixed(1)} / ${(s.swap_total_mb / 1024).toFixed(1)} GB`, "", s.swap_total_mb ? (s.swap_used_mb / s.swap_total_mb) * 100 : 0),
        card("Disk", `${s.disk_used_pct.toFixed(0)}% used`, `${s.disk_free_gb.toFixed(1)} GB free of ${s.disk_total_gb.toFixed(0)} GB`, s.disk_used_pct));
    } catch (e) { grid.replaceChildren(h("p", { class: "err" }, String(e))); }
  };
  load();
  boxTimer = every(10000, () => boxLive("system") && load());
}

function boxTmux(body) {
  const list = h("ul", { class: "tmux-list" });
  const pane = h("div", { class: "tmux-pane" }, h("p", { class: "muted pad" }, "Pick a tmux session."));
  body.append(h("div", { class: "split" }, list, pane));
  let current = null;
  const loadList = async () => {
    try {
      const r = await api("GET", "/box/tmux");
      list.replaceChildren(...r.sessions.map((s) => h("li", { class: `tmux ${current === s.name ? "active" : ""}`, onclick: () => { current = s.name; loadList(); openPane(s.name); } },
        h("div", { class: "mono" }, s.name),
        h("div", { class: "small muted" }, `${s.windows} win · ${s.attached ? "attached · " : ""}idle ${s.idle_hours != null ? `${Number(s.idle_hours).toFixed(1)}h` : "?"}`))));
    } catch (e) { list.replaceChildren(h("li", { class: "err" }, String(e))); }
  };
  const openPane = (name) => {
    const out = h("pre", { class: "term mono" }, "…");
    const keys = h("input", { class: "mono wide", placeholder: "Keys to send (Enter is added)" });
    const auto = h("input", { type: "checkbox", checked: true });
    let following = true, lastTop = 0;
    out.addEventListener("scroll", () => {
      const dist = out.scrollHeight - out.scrollTop - out.clientHeight;
      if (dist <= 24) following = true; else if (out.scrollTop < lastTop - 1) following = false;
      lastTop = out.scrollTop;
    }, { passive: true });
    const refresh = async () => {
      try {
        const r = await api("GET", `/box/tmux/${enc(name)}/capture?lines=400`);
        if (out.textContent !== r.text) {
          out.textContent = r.text;
          if (following) { out.scrollTop = out.scrollHeight; lastTop = out.scrollTop; }
        }
      } catch (e) { out.textContent = String(e); }
    };
    const sendKeys = async () => {
      if (!keys.value) return;
      try { await api("POST", `/box/tmux/${enc(name)}/send`, { keys: keys.value }); keys.value = ""; following = true; setTimeout(refresh, 400); } catch (e) { fail(e); }
    };
    keys.addEventListener("keydown", (e) => e.key === "Enter" && sendKeys());
    pane.replaceChildren(
      h("div", { class: "pane-head" },
        h("strong", { class: "mono" }, name),
        h("label", { class: "small muted check-label" }, auto, "Auto-refresh"),
        h("button", { class: "btn ghost", onclick: refresh }, "Refresh"),
        h("button", { class: "btn ghost danger", onclick: async () => {
          if (!(await confirmBox("Kill tmux session?", `Kills ${name}.`, "Kill"))) return;
          try { await api("DELETE", `/box/tmux/${enc(name)}`); current = null; pane.replaceChildren(h("p", { class: "muted pad" }, "Killed.")); loadList(); } catch (e) { fail(e); }
        } }, "Kill")),
      out,
      h("div", { class: "row pad" }, keys, h("button", { class: "btn primary", onclick: sendKeys }, "Send")));
    refresh();
    clearInterval(boxTimer);
    timers.delete(boxTimer);
    boxTimer = every(2000, () => boxLive("tmux") && current === name && auto.checked && refresh());
  };
  loadList();
}

function boxServices(body) {
  const tbl = h("table", { class: "svc" });
  body.append(tbl);
  const load = async () => {
    try {
      const r = await api("GET", "/box/services");
      tbl.replaceChildren(...r.services.map((s) => h("tr", {},
        h("td", { class: "mono" }, s.name),
        h("td", {}, h("span", { class: `pill ${s.active === "active" ? "ok" : "bad"}` }, s.active)),
        h("td", { class: "small muted" }, s.enabled),
        h("td", { class: "right" }, ["start", "stop", "restart"].map((a) => h("button", { class: `btn ghost small ${a === "stop" ? "danger" : ""}`, onclick: async () => {
          const warn = U.serviceConfirm(s.name, a);
          if (warn && !(await confirmBox(`${a[0].toUpperCase()}${a.slice(1)} ${s.name}?`, warn, a[0].toUpperCase() + a.slice(1)))) return;
          try { const res = await api("POST", `/box/services/${enc(s.name)}/${a}`, null, 90); if (res.error) toast(res.error, "bad"); else toast(`${s.name}: ${res.active}`); load(); } catch (e) { fail(e); }
        } }, a))))));
    } catch (e) { tbl.replaceChildren(h("tr", {}, h("td", { class: "err" }, String(e)))); }
  };
  load();
}

function boxShell(body) {
  const cmd = h("input", { class: "mono wide", placeholder: "Command (runs bash -lc on the box)", spellcheck: "false" });
  const cwd = h("input", { class: "mono", value: "/root", spellcheck: "false", style: { width: "220px" } });
  const out = h("pre", { class: "term mono" }, "Run a command to see output here.");
  const run = h("button", { class: "btn primary" }, "Run");
  const hist = [];
  let hi = -1;
  const go = async () => {
    const c = cmd.value.trim();
    if (!c || run.disabled) return;
    if (U.riskyCommand(c) && !(await confirmBox("Run this on the box?", h("code", { class: "mono" }, c), "Run"))) return;
    hist.unshift(c); hi = -1;
    run.disabled = true;
    out.textContent = `$ ${c}\n…`;
    try {
      const r = await api("POST", "/box/shell", { cmd: c, cwd: cwd.value.trim() || null, timeout: 600 }, 620);
      out.textContent = `$ ${c}\n${r.output || ""}\n[exit ${r.exit}]`;
      out.scrollTop = out.scrollHeight;
    } catch (e) { out.textContent = `$ ${c}\n${e}`; }
    run.disabled = false;
    cmd.select();
  };
  run.onclick = go;
  cmd.addEventListener("keydown", (e) => {
    if (e.key === "Enter") go();
    else if (e.key === "ArrowUp" && hist.length) { hi = Math.min(hi + 1, hist.length - 1); cmd.value = hist[hi]; e.preventDefault(); }
    else if (e.key === "ArrowDown") { hi = Math.max(hi - 1, -1); cmd.value = hi >= 0 ? hist[hi] : ""; e.preventDefault(); }
  });
  body.append(h("div", { class: "row pad" }, cwd, cmd, run), out);
  setTimeout(() => cmd.focus(), 30);
}

function boxBurst(body) {
  const wrap = h("div", { class: "cards" }, h("p", { class: "muted" }, "Checking GPU burst containers… (this can take ~30s)"));
  body.append(wrap);
  const busy = new Set();
  let models = null;
  const render = () => {
    if (!models.length) { wrap.replaceChildren(h("p", { class: "muted" }, "No GPU burst launchers on the box.")); return; }
    wrap.replaceChildren(...models.map((m) => {
      const [color] = hstyle(m.model);
      const act = (action, label, kind) => h("button", { class: `btn ${kind}`, disabled: busy.has(m.model), onclick: () => doAct(m, action) }, label);
      return h("div", { class: "card" },
        h("div", { class: "card-label" }, m.target || ""),
        h("div", { class: "card-value", style: { color } }, m.model.toUpperCase()),
        h("div", { class: `small mono ${m.held ? "ok-text" : "muted"}` }, busy.has(m.model) ? "working…" : U.burstState(m)),
        m.detail ? h("pre", { class: "mono small detail" }, m.detail) : null,
        h("div", { class: "row card-actions" },
          m.held ? act("release", "Release", "ghost danger") : act("warm", "Warm", "primary"),
          act("status", "Status", "ghost")));
    }));
  };
  const load = async () => {
    try { models = (await api("GET", "/box/burst", null, 120)).models || []; render(); }
    catch (e) { wrap.replaceChildren(h("p", { class: "err" }, String(e))); }
  };
  const doAct = async (m, action) => {
    if (action === "release" && !(await confirmBox(`Release ${m.model.toUpperCase()}?`, "Lets the container scale to zero. A chat using it will cold-start again (~3 min).", "Release"))) return;
    busy.add(m.model); render();
    try {
      const r = await api("POST", `/box/burst/${enc(m.model)}/${action}`, null, 120);
      if (r.ok === false) toast(r.error || r.detail || `${action} failed`, "bad");
      else toast(`${m.model}: ${(r.detail || "ok").split("\n")[0].slice(0, 140)}`, "good");
      if (action === "status" && r.detail) m.detail = r.detail;
    } catch (e) { fail(e); }
    busy.delete(m.model);
    if (boxLive("burst")) { if (action === "status") render(); else load(); }
  };
  load();
}

function boxReaper(body) {
  const panel = h("div", { class: "reaper" }, h("p", { class: "muted" }, "Loading…"));
  body.append(panel);
  let st = null;
  const save = async (patch) => {
    try { st = await api("PUT", "/box/reaper", patch); render(); } catch (e) { fail(e); load(); }
  };
  const render = () => {
    const cfg = st.config || {};
    const enabled = h("input", { type: "checkbox", checked: !!cfg.enabled, onchange: (e) => save({ enabled: e.target.checked }) });
    const nonHelm = h("input", { type: "checkbox", checked: !!cfg.include_non_helm, onchange: (e) => save({ include_non_helm: e.target.checked }) });
    const hours = h("input", { type: "number", min: 1, max: 336, step: 1, value: cfg.idle_hours, class: "mono num" });
    hours.addEventListener("change", () => {
      const v = Math.round(Number(hours.value));
      if (!(v >= 1 && v <= 336)) { toast("Idle hours must be 1 to 336", "bad"); hours.value = cfg.idle_hours; return; }
      if (v !== cfg.idle_hours) save({ idle_hours: v });
    });
    const cands = st.candidates || [];
    const last = st.last_run && st.last_run.at
      ? `Last run ${ago(st.last_run.at)} ago, killed ${(st.last_run.killed || []).length}.` : "Not run yet since helmd started.";
    const runBtn = h("button", { class: "btn danger", disabled: !cands.length, onclick: async () => {
      if (!(await confirmBox("Kill stale sessions?", `Kills ${cands.map((c) => c.name).join(", ")}. Killed chats can be resumed.`, "Kill"))) return;
      try { const r = await api("POST", "/box/reaper/run"); toast(`Killed ${(r.killed || []).length}`, "good"); st = r; render(); } catch (e) { fail(e); }
    } }, U.reaperRunLabel(st));
    panel.replaceChildren(
      h("label", { class: "check-label" }, enabled, "Auto-kill idle tmux sessions"),
      h("label", { class: "check-label" }, "After", hours, "hours idle"),
      h("label", { class: "check-label" }, nonHelm, "Include non-Helm sessions"),
      h("p", { class: "small muted" }, `Checked every ${Math.round((st.interval_seconds || 900) / 60)} min. Attached sessions and "main" are never killed. Killed chats can be resumed. ${last}`),
      cands.length ? h("ul", { class: "cands mono small" }, cands.map((c) => h("li", {}, `${c.name}  idle ${c.idle_hours != null ? Number(c.idle_hours).toFixed(1) : "?"}h`))) : null,
      h("div", { class: "row" }, runBtn, h("button", { class: "btn ghost", onclick: load }, "Refresh")));
  };
  const load = async () => {
    try { st = await api("GET", "/box/reaper"); if (boxLive("reaper")) render(); }
    catch (e) { panel.replaceChildren(h("p", { class: "err" }, String(e))); }
  };
  load();
}

// ---------- Files ----------
let filesPath = "/root";
const fPath = $("f-path");
fPath.addEventListener("keydown", (e) => e.key === "Enter" && listFiles(fPath.value.trim()));
$("f-refresh").onclick = () => listFiles(filesPath);
$("f-up").onclick = () => listFiles(filesPath.replace(/\/[^/]+\/?$/, "") || "/");
$("f-mkdir").onclick = async () => {
  const n = await ask("New folder", "Name");
  if (!n || !n.trim()) return;
  try { await api("POST", "/box/fs/mkdir", { path: `${filesPath.replace(/\/$/, "")}/${n.trim()}` }); listFiles(filesPath); } catch (e) { fail(e); }
};
$("f-upload").onclick = async () => {
  const picked = await T.dialog.open({ multiple: true, title: `Upload to ${filesPath}` });
  if (picked) uploadToFolder(Array.isArray(picked) ? picked : [picked]);
};
async function uploadToFolder(paths) {
  const dir = filesPath;
  for (const p of paths) {
    const name = p.split(/[\\/]/).pop();
    toast(`Uploading ${name}…`);
    try { const r = await invoke("upload", { endpoint: "/box/upload", localPath: p, fields: { dir } }); toast(`Uploaded ${r.path.split("/").pop()} (${bytes(r.size)})`, "good"); }
    catch (e) {
      // A dropped folder: upload it recursively instead of failing.
      if (/: not a file$/.test(String(e))) await uploadFolder(p, dir);
      else fail(e);
    }
  }
  if (view === "files" && filesPath === dir) listFiles(dir);
}

$("f-upload-dir").onclick = async () => {
  const picked = await T.dialog.open({ directory: true, multiple: false, title: `Upload a folder to ${filesPath}` });
  if (picked) await uploadFolder(Array.isArray(picked) ? picked[0] : picked, filesPath);
};

// Recursive folder upload, done in Rust (one /box/upload per file with rel).
// Progress arrives as "folder-upload" events for this job id.
const folderJobs = new Map();
T.event.listen("folder-upload", (e) => {
  const p = e.payload;
  const j = folderJobs.get(p.job);
  if (!j) return;
  j.done = p.done;
  j.total = p.total;
  if (p.error) j.errors.push(`${p.rel}: ${p.error}`);
  renderJob(j);
});
function renderJob(j) {
  const pct = j.total ? (j.done / j.total) * 100 : 0;
  j.el.replaceChildren(
    h("div", { class: "job-head" },
      h("span", {}, j.result ? U.folderSummary(j.result) : U.folderProgressText(j.name, j.done, j.total, j.errors.length)),
      j.result || j.fatal ? h("button", { class: "btn ghost small", onclick: () => { j.el.remove(); folderJobs.delete(j.id); } }, "Dismiss") : null),
    j.result || j.fatal ? null : h("div", { class: "bar" }, h("i", { style: { width: `${pct}%`, background: "var(--lime)" } })),
    j.fatal ? h("div", { class: "err small" }, j.fatal) : null,
    j.errors.length ? h("details", { open: !!j.result },
      h("summary", { class: "small err" }, `${j.errors.length} failed`),
      h("ul", { class: "job-errs mono small" }, j.errors.map((x) => h("li", {}, x)))) : null);
}
async function uploadFolder(localDir, remoteDir) {
  const name = localDir.replace(/[\\/]+$/, "").split(/[\\/]/).pop();
  const j = { id: cid(), name, done: 0, total: 0, errors: [], result: null, fatal: null, el: h("div", { class: "job" }) };
  folderJobs.set(j.id, j);
  $("f-jobs").append(j.el);
  renderJob(j);
  try {
    j.result = await invoke("upload_folder", { job: j.id, localDir, remoteDir });
    // Event order vs. the returned value isn't guaranteed; the result is the record.
    j.errors = (j.result.failed || []).map((f) => `${f.rel}: ${f.error}`);
    toast(U.folderSummary(j.result), j.errors.length ? "bad" : "good");
  } catch (e) { j.fatal = String(e); fail(e); }
  renderJob(j);
  if (view === "files" && filesPath === remoteDir) listFiles(remoteDir);
}

async function listFiles(path) {
  try {
    const r = await api("GET", `/box/fs/list?path=${enc(path)}`);
    filesPath = r.path;
    fPath.value = r.path;
    const full = (e) => `${r.path.replace(/\/$/, "")}/${e.name}`;
    $("f-list").replaceChildren(...r.entries.map((e) => h("tr", { class: e.is_dir ? "dir" : "" },
      h("td", { class: "fname", onclick: () => e.is_dir && listFiles(full(e)) }, h("span", { class: "ficon" }, e.is_dir ? "▸" : "·"), e.name, e.is_link ? h("span", { class: "muted small" }, " ↪") : null),
      h("td", { class: "small muted right" }, e.is_dir ? "" : bytes(e.size)),
      h("td", { class: "small muted right" }, e.mtime ? new Date(e.mtime * 1000).toLocaleString() : ""),
      h("td", { class: "right actions" },
        h("button", { class: "btn ghost small", onclick: () => downloadEntry(full(e), e) }, "Download"),
        h("button", { class: "btn ghost small", onclick: async () => {
          const n = await ask("Rename", "New name", e.name);
          if (!n || n === e.name) return;
          try { await api("POST", "/box/fs/move", { src: full(e), dst: `${r.path.replace(/\/$/, "")}/${n}` }); listFiles(r.path); } catch (er) { fail(er); }
        } }, "Rename"),
        h("button", { class: "btn ghost small danger", onclick: async () => {
          if (!(await confirmBox(`Delete ${e.name}?`, "It moves to the box trash (~/.helm/trash) and is purged after 7 days."))) return;
          try { await api("POST", "/box/fs/delete", { path: full(e) }); listFiles(r.path); } catch (er) { fail(er); }
        } }, "Delete")))));
  } catch (e) { fail(e); }
}
async function downloadEntry(remote, e) {
  const dest = await T.dialog.save({ defaultPath: e.is_dir ? `${e.name}.zip` : e.name, title: "Save as" });
  if (!dest) return;
  toast(`Downloading ${e.name}…`);
  try { const n = await invoke("download", { remotePath: remote, dest }); toast(`Saved ${bytes(n)}`, "good"); } catch (er) { fail(er); }
}

// ---------- shortcuts ----------
document.addEventListener("keydown", (e) => {
  if (!unlocked || !e.ctrlKey) return;
  if (e.key === "n" || e.key === "N") { e.preventDefault(); newChat(); }
  if (e.key === "l" || e.key === "L") { e.preventDefault(); lockNow(); }
});
