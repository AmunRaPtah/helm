//! Helm for Windows: native shell around the Helm web UI.
//!
//! The UI never sees credentials. They are compiled in as `creds.bin`,
//! encrypted with the owner's password (scrypt + AES-256-GCM, see
//! tools/seal.py). `unlock` decrypts them into memory; every request to
//! helmd then goes through this process over mTLS with the bearer token.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, State};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::Message;
use zeroize::Zeroize;

static SEALED: &[u8] = include_bytes!("../creds.bin");
const MAGIC: &[u8] = b"HELMW1";

#[derive(Deserialize)]
struct Creds {
    base: String,
    token: String,
    cert_pem: String,
    key_pem: String,
}

struct Conn {
    base: String,
    token: String,
    http: reqwest::Client,
    tls: Arc<rustls::ClientConfig>,
}

#[derive(Default)]
struct AppState {
    conn: Mutex<Option<Arc<Conn>>>,
    streams: Mutex<HashMap<u64, mpsc::UnboundedSender<Option<String>>>>,
    next_stream: AtomicU64,
    failures: AtomicU32,
}

fn decrypt(password: &str) -> Result<Creds, String> {
    let min = MAGIC.len() + 16 + 12 + 16;
    if SEALED.len() < min || &SEALED[..MAGIC.len()] != MAGIC {
        return Err("This build has no sealed credentials.".into());
    }
    let salt = &SEALED[MAGIC.len()..MAGIC.len() + 16];
    let nonce = &SEALED[MAGIC.len() + 16..MAGIC.len() + 28];
    let ct = &SEALED[MAGIC.len() + 28..];
    let params = scrypt::Params::new(17, 8, 1, 32).map_err(|e| e.to_string())?;
    let mut key = [0u8; 32];
    scrypt::scrypt(password.as_bytes(), salt, &params, &mut key).map_err(|e| e.to_string())?;
    let cipher = Aes256Gcm::new_from_slice(&key).map_err(|e| e.to_string())?;
    key.zeroize();
    let mut plain = cipher
        .decrypt(Nonce::from_slice(nonce), ct)
        .map_err(|_| "Wrong password.".to_string())?;
    let creds: Result<Creds, String> =
        serde_json::from_slice(&plain).map_err(|e| format!("Bad credentials: {e}"));
    plain.zeroize();
    creds
}

fn tls_config(c: &Creds) -> Result<rustls::ClientConfig, String> {
    let certs = rustls_pemfile::certs(&mut c.cert_pem.as_bytes())
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| format!("cert: {e}"))?;
    let key = rustls_pemfile::private_key(&mut c.key_pem.as_bytes())
        .map_err(|e| format!("key: {e}"))?
        .ok_or("no private key in credentials")?;
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_root_certificates(roots)
        .with_client_auth_cert(certs, key)
        .map_err(|e| format!("client cert: {e}"))
}

async fn conn(state: &State<'_, AppState>) -> Result<Arc<Conn>, String> {
    state.conn.lock().await.clone().ok_or_else(|| "locked".to_string())
}

fn url(c: &Conn, path: &str) -> String {
    format!("{}{}", c.base.trim_end_matches('/'), path)
}

async fn into_json(resp: reqwest::Response) -> Result<Value, String> {
    let status = resp.status();
    let text = resp.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.get("detail").map(|d| d.as_str().map(String::from).unwrap_or(d.to_string())))
            .unwrap_or(text);
        return Err(format!("HTTP {}: {}", status.as_u16(), detail));
    }
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|e| format!("bad JSON from server: {e}"))
}

#[tauri::command]
async fn unlock(password: String, state: State<'_, AppState>) -> Result<(), String> {
    // Slow down guessing: each failure adds a second before the next try.
    let fails = state.failures.load(Ordering::SeqCst);
    if fails > 0 {
        tokio::time::sleep(Duration::from_secs(fails.min(30) as u64)).await;
    }
    let result = tokio::task::spawn_blocking(move || {
        let mut pw = password;
        let r = decrypt(&pw);
        pw.zeroize();
        r
    })
    .await
    .map_err(|e| e.to_string())?;
    let creds = match result {
        Ok(c) => c,
        Err(e) => {
            state.failures.fetch_add(1, Ordering::SeqCst);
            return Err(e);
        }
    };
    state.failures.store(0, Ordering::SeqCst);
    let tls = Arc::new(tls_config(&creds)?);
    let http = reqwest::Client::builder()
        .use_preconfigured_tls((*tls).clone())
        .connect_timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    *state.conn.lock().await = Some(Arc::new(Conn { base: creds.base, token: creds.token, http, tls }));
    Ok(())
}

#[tauri::command]
async fn lock(state: State<'_, AppState>) -> Result<(), String> {
    *state.conn.lock().await = None;
    for (_, tx) in state.streams.lock().await.drain() {
        let _ = tx.send(None);
    }
    Ok(())
}

#[tauri::command]
async fn api(
    method: String,
    path: String,
    body: Option<Value>,
    timeout_secs: Option<u64>,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let c = conn(&state).await?;
    let m = reqwest::Method::from_bytes(method.to_uppercase().as_bytes()).map_err(|e| e.to_string())?;
    let mut req = c
        .http
        .request(m, url(&c, &path))
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(timeout_secs.unwrap_or(120)));
    if let Some(b) = body {
        req = req.json(&b);
    }
    into_json(req.send().await.map_err(|e| format!("Network: {e}"))?).await
}

/// Multipart upload of a local file. `fields` become extra form fields.
#[tauri::command]
async fn upload(
    endpoint: String,
    local_path: String,
    fields: HashMap<String, String>,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let c = conn(&state).await?;
    let data = tokio::fs::read(&local_path).await.map_err(|e| format!("{local_path}: {e}"))?;
    let name = std::path::Path::new(&local_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "upload".into());
    let mut form = reqwest::multipart::Form::new().part("file", reqwest::multipart::Part::bytes(data).file_name(name));
    for (k, v) in fields {
        form = form.text(k, v);
    }
    let resp = c
        .http
        .post(url(&c, &endpoint))
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(3600))
        .multipart(form)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    into_json(resp).await
}

/// Stream a box file (or zipped folder) to a local path.
#[tauri::command]
async fn download(remote_path: String, dest: String, state: State<'_, AppState>) -> Result<u64, String> {
    use tokio::io::AsyncWriteExt;
    let c = conn(&state).await?;
    let resp = c
        .http
        .get(url(&c, "/box/fs/download"))
        .query(&[("path", remote_path.as_str())])
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(6 * 3600))
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    if !resp.status().is_success() {
        return into_json(resp).await.map(|_| 0);
    }
    let part = format!("{dest}.part");
    let mut f = tokio::fs::File::create(&part).await.map_err(|e| e.to_string())?;
    let mut stream = resp.bytes_stream();
    let mut total = 0u64;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        total += chunk.len() as u64;
        f.write_all(&chunk).await.map_err(|e| e.to_string())?;
    }
    f.flush().await.map_err(|e| e.to_string())?;
    drop(f);
    let _ = tokio::fs::remove_file(&dest).await;
    tokio::fs::rename(&part, &dest).await.map_err(|e| e.to_string())?;
    Ok(total)
}

/// Open the live event stream for a session. Frames arrive as `ws` events:
/// `{id, data}` per frame, then `{id, closed: true, error?}` once.
#[tauri::command]
async fn ws_open(session_id: String, after: u64, app: AppHandle, state: State<'_, AppState>) -> Result<u64, String> {
    let c = conn(&state).await?;
    let id = state.next_stream.fetch_add(1, Ordering::SeqCst) + 1;
    let ws_base = c.base.replacen("https://", "wss://", 1).replacen("http://", "ws://", 1);
    let target = format!("{}/sessions/{}/stream?after={}", ws_base.trim_end_matches('/'), session_id, after);
    let mut req = target.into_client_request().map_err(|e| e.to_string())?;
    req.headers_mut().insert(
        "Authorization",
        format!("Bearer {}", c.token).parse().map_err(|_| "bad token".to_string())?,
    );
    let (tx, mut rx) = mpsc::unbounded_channel::<Option<String>>();
    state.streams.lock().await.insert(id, tx);
    let tls = c.tls.clone();
    tauri::async_runtime::spawn(async move {
        let connector = tokio_tungstenite::Connector::Rustls(tls);
        let connected = tokio::time::timeout(
            Duration::from_secs(20),
            tokio_tungstenite::connect_async_tls_with_config(req, None, false, Some(connector)),
        )
        .await;
        let ws = match connected {
            Ok(Ok((ws, _))) => ws,
            Ok(Err(e)) => {
                let _ = app.emit("ws", json!({"id": id, "closed": true, "error": e.to_string()}));
                return;
            }
            Err(_) => {
                let _ = app.emit("ws", json!({"id": id, "closed": true, "error": "connect timed out"}));
                return;
            }
        };
        let (mut sink, mut source) = ws.split();
        let mut error: Option<String> = None;
        loop {
            tokio::select! {
                out = rx.recv() => match out {
                    Some(Some(text)) => {
                        if let Err(e) = sink.send(Message::Text(text)).await { error = Some(e.to_string()); break; }
                    }
                    _ => { let _ = sink.close().await; break; }
                },
                // helmd pings every 20s; 60s of silence means the link is dead.
                frame = tokio::time::timeout(Duration::from_secs(60), source.next()) => match frame {
                    Ok(Some(Ok(Message::Text(t)))) => { let _ = app.emit("ws", json!({"id": id, "data": t})); }
                    Ok(Some(Ok(Message::Ping(p)))) => { let _ = sink.send(Message::Pong(p)).await; }
                    Ok(Some(Ok(Message::Close(_)))) | Ok(None) => break,
                    Ok(Some(Ok(_))) => {}
                    Ok(Some(Err(e))) => { error = Some(e.to_string()); break; }
                    Err(_) => { error = Some("stream went quiet".into()); break; }
                }
            }
        }
        let _ = app.emit("ws", json!({"id": id, "closed": true, "error": error}));
    });
    Ok(id)
}

#[tauri::command]
async fn ws_send(id: u64, text: String, state: State<'_, AppState>) -> Result<(), String> {
    match state.streams.lock().await.get(&id) {
        Some(tx) => tx.send(Some(text)).map_err(|_| "stream closed".to_string()),
        None => Err("stream closed".into()),
    }
}

#[tauri::command]
async fn ws_close(id: u64, state: State<'_, AppState>) -> Result<(), String> {
    if let Some(tx) = state.streams.lock().await.remove(&id) {
        let _ = tx.send(None);
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![unlock, lock, api, upload, download, ws_open, ws_send, ws_close])
        .run(tauri::generate_context!())
        .expect("error while running Helm");
}
