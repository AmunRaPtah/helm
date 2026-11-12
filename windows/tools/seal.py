#!/usr/bin/env python3
"""Seal Helm credentials for the Windows build.

Writes src-tauri/creds.bin = b"HELMW1" | salt(16) | nonce(12) | AES-256-GCM(
  JSON {base, token, cert_pem, key_pem}) with key = scrypt(password, N=2^17,
  r=8, p=1, 32 bytes). Must match decrypt() in src-tauri/src/lib.rs.

The password is read from the HELM_APP_PASSWORD env var, or prompted for.
creds.bin is gitignored: the repo is public.

  python3 tools/seal.py --cert CERT.pem --key KEY.pem [--token-file F] [--base URL]
"""
import argparse, getpass, hashlib, json, os, sys
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ap = argparse.ArgumentParser()
ap.add_argument("--cert", required=True)
ap.add_argument("--key", required=True)
ap.add_argument("--token-file", default=os.path.expanduser("~/.helm/token"))
ap.add_argument("--base", default="https://helm.178-18-250-254.sslip.io")
ap.add_argument("--out", default=str(Path(__file__).resolve().parent.parent / "src-tauri" / "creds.bin"))
a = ap.parse_args()

pw = os.environ.get("HELM_APP_PASSWORD") or getpass.getpass("App password: ")
if not pw:
    sys.exit("empty password")
payload = json.dumps({
    "base": a.base,
    "token": Path(a.token_file).read_text().strip(),
    "cert_pem": Path(a.cert).read_text(),
    "key_pem": Path(a.key).read_text(),
}).encode()
salt, nonce = os.urandom(16), os.urandom(12)
key = hashlib.scrypt(pw.encode(), salt=salt, n=2**17, r=8, p=1, maxmem=256 * 1024 * 1024, dklen=32)
blob = b"HELMW1" + salt + nonce + AESGCM(key).encrypt(nonce, payload, None)
out = Path(a.out)
out.write_bytes(blob)
os.chmod(out, 0o600)
print(f"sealed {len(blob)} bytes -> {out}")
