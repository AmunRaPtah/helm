// Pure helpers (no DOM, no Tauri), shared by app.js and the node tests.
"use strict";
(function (root) {
  // Chat banner while helmd revives a dead runner (status state "starting").
  function reconnectText(state, harnessName) {
    return state === "starting" ? `Reconnecting to ${harnessName || "harness"}…` : null;
  }

  // Shell commands worth a second look before they run on the box.
  const RISKY = [
    /(^|[;&|(]\s*|\b(sudo|xargs|exec|-exec)\s+)rm(\s|$)/, /(^|[;&|(]\s*|\b(sudo|xargs)\s+)(kill|pkill|killall)(\s|$)/, /\b(reboot|shutdown|poweroff|halt)\b/,
    /\bsystemctl\s+(stop|restart|disable|mask|kill)\b/, /\bdocker\s+(rm|rmi|kill|stop|system\s+prune|volume\s+rm)\b/,
    /\b(mkfs|fdisk|parted|wipefs)\b/, /\bdd\s/, /\btmux\s+kill/, /\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s+.*--force)/,
    /\bchmod\s+-R\b/, /\bchown\s+-R\b/, /\btruncate\s/, /(^|[^>&0-9])>\s*\/(etc|root|boot|usr|var)\//,
  ];
  const riskyCommand = (cmd) => RISKY.some((re) => re.test(String(cmd || "")));

  // "Uploading Photos: 3/10 (1 failed)"
  function folderProgressText(name, done, total, failed) {
    const f = failed ? ` (${failed} failed)` : "";
    return total === 0 && done === 0 ? `Uploading ${name}: scanning…` : `Uploading ${name}: ${done}/${total}${f}`;
  }

  // Final line for a finished folder upload result {path, total, uploaded, failed}.
  function folderSummary(r) {
    const dest = String(r.path || "").split("/").pop();
    const nf = (r.failed || []).length;
    if (!r.total && !nf) return `${dest}: folder was empty, created it`;
    return nf ? `${dest}: ${r.uploaded}/${r.total} files uploaded, ${nf} failed` : `${dest}: ${r.uploaded} files uploaded`;
  }

  // Reaper button label from GET /box/reaper.
  function reaperRunLabel(r) {
    const n = ((r && r.candidates) || []).length;
    return n ? `Kill ${n} stale now` : "No stale sessions";
  }

  // GPU burst row state from {held, detail}.
  function burstState(m) {
    return m.held ? "container pinned" : "scaled to zero";
  }

  // Destructive service actions; helmd itself drops this app's connection.
  function serviceConfirm(name, action) {
    if (action === "start") return null;
    if (name === "helmd") return `${action === "stop" ? "Stopping" : "Restarting"} helmd cuts this app off from the box${action === "stop" ? " until it is started from a shell" : " for a few seconds"}.`;
    if (/^wg-quick@/.test(name) || name === "caddy") return `${action === "stop" ? "Stopping" : "Restarting"} ${name} can drop the connection this app uses.`;
    return action === "stop" ? `Stop ${name}?` : null;
  }

  // Mirrors helmd adapters.LONG_LIVED: harnesses with a persistent runner.
  const LONG_LIVED = ["claude", "ds", "cc", "agy", "glm", "dsv", "sukuna", "venice", "api"];
  const api = { LONG_LIVED, reconnectText, riskyCommand, folderProgressText, folderSummary, reaperRunLabel, burstState, serviceConfirm };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.HelmUtil = api;
})(typeof window !== "undefined" ? window : globalThis);
