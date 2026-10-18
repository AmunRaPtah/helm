# Helm for iOS

Native SwiftUI chat client for the CLI coding harnesses (Claude Code, Codex,
agy, ...) running on the box. Each chat is a harness session in tmux, served by
`helmd` (see `../PROTOCOL.md`).

## Install

1. On the phone, open the latest release and download `Helm.ipa`:
   https://github.com/AmunRaPtah/helm/releases/tag/latest
   (the repo is private, so sign in to GitHub in Safari first).
2. Open the IPA with **SideStore** or **AltStore** ("+" in My Apps, pick the
   file). It is unsigned; the sideloading app signs it with your Apple ID.
3. Free Apple IDs expire sideloaded apps after 7 days. Refresh from SideStore /
   AltStore before then.

Every push to `main` that touches `ios/` rebuilds the IPA on GitHub Actions and
replaces the `latest` release asset.

## First run

1. Turn **WireGuard** on. helmd only listens on the wg0 address.
2. Server URL: `http://10.66.66.1:3340` (prefilled).
3. Token: copy it from Bitwarden item **"Helm Token"** (on the box:
   `bw-get "Helm Token"`, or `cat ~/.helm/token`). Paste it into the token field.
   It is stored in the iOS Keychain.
4. Tap **Test connection**. It calls `/health` and then `/harnesses` and
   lists the harnesses it found. Then tap **Connect**.

## Using it

- **Chats**: sorted by last activity. The dot shows state: pulsing green is
  running, blue is idle, grey is exited. Pull to refresh; swipe to delete.
- **New chat**: pick a harness (and a cx profile for Codex), a working
  directory (browsed live from the box, recents remembered), a permission mode
  and optional model, and type the first message.
- **Chat**: streams live over WebSocket and resumes from the last event after
  network drops. Tool calls are collapsible cards, thinking is dimmed and
  collapsible. Stop interrupts the current turn. Exited sessions show a Resume
  banner. The menu has rename, copy `tmux attach -t hx-<id>`, and delete.
- Sessions and transcripts are cached on the device, so the app opens instantly
  offline and syncs when the server is reachable.

## Building

No Xcode on the box. CI (`.github/workflows/build-ipa.yml`) runs on macOS:
`brew install xcodegen`, `xcodegen generate` from `ios/project.yml`, then an
unsigned `xcodebuild` for `generic/platform=iOS`, packaged as `Payload/Helm.app`
in `Helm.ipa`. Locally on a Mac: `cd ios && xcodegen generate && open Helm.xcodeproj`.
