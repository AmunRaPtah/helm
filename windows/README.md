# Helm for Windows

A desktop client for helmd, built with Tauri 2: Chats, Box (system, tmux, services, shell) and Files.
It connects to the public mTLS route (`https://helm.178-18-250-254.sslip.io`) with its own client
certificate (`CN=helm-windows-1`).

## How the password works

The server address, bearer token, client certificate and key are sealed into `src-tauri/creds.bin`
(scrypt N=2^17, r=8, p=1, then AES-256-GCM) and compiled into the exe. Nothing secret is stored in
plain text. The app can't reach the box until the right password is entered. Wrong attempts slow
down progressively. The app locks after 30 minutes idle, or on Ctrl+L.

`creds.bin` is git-ignored and must never be committed: this repo is public.

## Build (Linux, cross-compiling)

```sh
# one-time: rustup target add x86_64-pc-windows-msvc; cargo install --locked cargo-xwin
#           apt install nsis lld llvm clang; npm install
# On this box ~/.local/bin/cc shadows the C compiler, so put /usr/bin first:
export PATH=$HOME/.cargo/bin:/usr/bin:$PATH

# seal credentials (prompts for the app password, or reads HELM_APP_PASSWORD)
python3 tools/seal.py --cert ~/.helm/pki/windows.pem --key ~/.helm/pki/windows.key

npx tauri build --runner cargo-xwin --target x86_64-pc-windows-msvc
# -> src-tauri/target/x86_64-pc-windows-msvc/release/bundle/nsis/Helm_<ver>_x64-setup.exe
```

The installer installs per-user (no admin needed). If WebView2 is missing, the installer downloads
it; it ships with Windows 11 and current Windows 10.

## Changing the password

Re-run `seal.py` with the new password and rebuild. Old installers keep the old password.

## Revoking the PC

Each device has its own cert, but Caddy currently trusts the whole Helm CA
(`trusted_ca_cert_file`). To cut off only the PC, pin the leaf certs Caddy accepts
(`trusted_leaf_cert_file`) and leave `windows.pem` out. In every case, rotate `~/.helm/token`
if it might have leaked.

## Shortcuts

Enter sends, Shift+Enter adds a new line, `/` completes commands, Ctrl+N opens a new chat,
Ctrl+L locks. Drop files on a chat to attach them, or on Files to upload them to the current folder.
