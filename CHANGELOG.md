# Changelog

Each app has its own version. Every update bumps it, and CI refuses to publish a version that
was already released.

- **iOS:** version in `ios/VERSION`. The build number is the CI run number, so Settings shows
  e.g. `1.1.0 (57)`. Releases are tagged `ios-v<version>`; `latest` always points at the newest.
- **Windows:** version in `windows/src-tauri/tauri.conf.json`, shown on the lock screen and in the
  sidebar. Tagged `windows-v<version>`.

Versions are `MAJOR.MINOR.PATCH`: patch for fixes, minor for features, major for breaking changes.

## iOS 1.1.1 (2026-11-12)
- Fix: a message sent from another device no longer removes your own in-flight message.
- Fix: Retry resends the failed message as-is instead of overwriting your draft.
- Fix: the Stop button and typing indicator no longer vanish for a few seconds mid-reply.
- Fix: a send that took a while (runner being revived) is no longer falsely marked failed.

## Windows 1.0.1 (2026-11-12)
- Fix: markdown links containing brackets or bold no longer produce broken markup.
- Fix: double-clicking Start no longer creates two chats; locking closes open dialogs.
- Fix: Delete really deletes (with a "Stop only" option) instead of the chat coming back.
- Fix: a typed slash command sends on one Enter; reconnect backoff resets on idle chats.
- Fix: uploads stream from disk, folders get a clear error, failed downloads leave no .part file.
- Hardening: request paths must start with `/`; streams opened while locking are closed.

## helmd (2026-11-12)
- Fix: a chat whose harness exited no longer 503s forever; it is shown as exited and revived on send.
- Fix: `!cmd` no longer orphans the harness and starts a second one.
- Fix: messages over ~64 KB are delivered instead of silently lost.
- Fix: a missing image attachment no longer crashes the chat.
- Fix: streamed text carries the real message id, so the live bubble is replaced by the final one.
- Fix: the WebSocket tails new bytes off the event loop instead of re-reading the whole log 5x/s.
- Fix: codex messages starting with `-`; tmux send of `-h`/key names; `/box` shell timeouts kill children.
- Hardening: session ids validated; unavailable harnesses rejected; reaper ignores foreign hx-* sessions.

## iOS 1.1.0 (2026-11-12)
- Fix: going back from a chat and tapping a chat could open a different one. The list was
  re-sorting under the tap; it now stays current while a chat is open and settles while going back.
- Fix: new output no longer scrolls you away from what you are reading (chat, tmux, shell).
- Redesigned look: theme, motion, restyled views, brand marks.
- Builds now carry a real version and build number.

## iOS 1.0.0 (2026-11-07 and earlier, unversioned builds)
- Chats with Claude Code, Codex and other harnesses; queueing, interrupt, resume.
- Box remote control (system, tmux, services, shell), Files tab, uploads.
- Public mTLS route with client-certificate import.

## Windows 1.0.0 (unreleased)
- First desktop release: chats, Box, Files, password lock, its own client certificate.
