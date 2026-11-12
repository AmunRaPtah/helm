# Changelog

Each app has its own version. Every update bumps it, and CI refuses to publish a version that
was already released.

- **iOS:** version in `ios/VERSION`. The build number is the CI run number, so Settings shows
  e.g. `1.1.0 (57)`. Releases are tagged `ios-v<version>`; `latest` always points at the newest.
- **Windows:** version in `windows/src-tauri/tauri.conf.json`, shown on the lock screen and in the
  sidebar. Tagged `windows-v<version>`.

Versions are `MAJOR.MINOR.PATCH`: patch for fixes, minor for features, major for breaking changes.

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
