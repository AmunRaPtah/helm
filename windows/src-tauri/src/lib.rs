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
use tauri::{AppHandle, Emitter, Manager, State};
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

/// Only absolute paths on the configured host. "@evil.example/x" or
/// ".evil.example/x" appended to the base would otherwise send the bearer
/// token to another host.
fn url(c: &Conn, path: &str) -> Result<String, String> {
    if !path.starts_with('/') {
        return Err(format!("bad path: {path}"));
    }
    Ok(format!("{}{}", c.base.trim_end_matches('/'), path))
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
        .request(m, url(&c, &path)?)
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(timeout_secs.unwrap_or(120)));
    if let Some(b) = body {
        req = req.json(&b);
    }
    into_json(req.send().await.map_err(|e| format!("Network: {e}"))?).await
}

/// Stream one local file as the multipart `file` part to `target`.
async fn upload_file(
    c: &Conn,
    target: &str,
    local_path: &std::path::Path,
    fields: Vec<(String, String)>,
) -> Result<Value, String> {
    let shown = local_path.display();
    // Stream the file instead of reading it whole into memory: a multi-GB
    // upload used to need that much RAM in the app.
    let file = tokio::fs::File::open(local_path).await.map_err(|e| format!("{shown}: {e}"))?;
    let meta = file.metadata().await.map_err(|e| format!("{shown}: {e}"))?;
    if !meta.is_file() {
        return Err(format!("{shown}: not a file"));
    }
    let len = meta.len();
    let body_stream = futures_util::stream::try_unfold(file, |mut f| async move {
        use tokio::io::AsyncReadExt;
        let mut buf = vec![0u8; 256 * 1024];
        let n = f.read(&mut buf).await?;
        if n == 0 {
            return Ok::<_, std::io::Error>(None);
        }
        buf.truncate(n);
        Ok(Some((buf, f)))
    });
    let name = local_path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "upload".into());
    let mut form = reqwest::multipart::Form::new().part("file", reqwest::multipart::Part::stream_with_length(reqwest::Body::wrap_stream(body_stream), len).file_name(name));
    for (k, v) in fields {
        form = form.text(k, v);
    }
    let resp = c
        .http
        .post(target)
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(3600))
        .multipart(form)
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    into_json(resp).await
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
    let target = url(&c, &endpoint)?;
    upload_file(&c, &target, std::path::Path::new(&local_path), fields.into_iter().collect()).await
}

/// Files and (empty-or-not) subfolders under `root`, as `/`-joined paths
/// relative to it. Symlinks are not followed, so a link loop can't recurse
/// forever; linked files are uploaded, linked folders are skipped.
fn walk_folder(root: &std::path::Path) -> Result<(Vec<(String, std::path::PathBuf)>, Vec<String>), String> {
    let mut files = Vec::new();
    let mut dirs = Vec::new();
    let mut stack = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, rel)) = stack.pop() {
        let mut entries: Vec<_> = std::fs::read_dir(&dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .filter_map(|e| e.ok())
            .collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let name = e.file_name().to_string_lossy().to_string();
            let child_rel = if rel.is_empty() { name.clone() } else { format!("{rel}/{name}") };
            let ft = match e.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            if ft.is_dir() {
                dirs.push(child_rel.clone());
                stack.push((e.path(), child_rel));
            } else if ft.is_file() || (ft.is_symlink() && e.path().is_file()) {
                files.push((child_rel, e.path()));
            }
        }
    }
    files.sort_by(|a, b| a.0.cmp(&b.0));
    dirs.sort();
    Ok((files, dirs))
}

/// Upload a local folder recursively into box folder `remote_dir`.
/// Creates `<remote_dir>/<name>` (made unique, so two uploads never merge),
/// then one /box/upload per file with `rel`. Progress arrives as
/// `folder-upload` events `{job, done, total, rel, error?}`.
#[tauri::command]
async fn upload_folder(
    job: String,
    local_dir: String,
    remote_dir: String,
    app: AppHandle,
    state: State<'_, AppState>,
) -> Result<Value, String> {
    let c = conn(&state).await?;
    let root = std::path::PathBuf::from(&local_dir);
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .ok_or_else(|| format!("{local_dir}: not a folder"))?;
    let walk_root = root.clone();
    let (files, dirs) = tokio::task::spawn_blocking(move || walk_folder(&walk_root))
        .await
        .map_err(|e| e.to_string())??;
    let mkdir = c
        .http
        .post(url(&c, "/box/fs/mkdir")?)
        .bearer_auth(&c.token)
        .timeout(Duration::from_secs(60))
        .json(&json!({"path": format!("{}/{}", remote_dir.trim_end_matches('/'), name), "unique": true}))
        .send()
        .await
        .map_err(|e| format!("Network: {e}"))?;
    let made = into_json(mkdir).await?;
    let dest = made
        .get("path")
        .and_then(|p| p.as_str())
        .ok_or("mkdir returned no path")?
        .to_string();
    let target = url(&c, "/box/upload")?;
    let total = files.len();
    let mut failed = Vec::new();
    let mut uploaded = 0usize;
    let mut bytes = 0u64;
    let _ = app.emit("folder-upload", json!({"job": job, "done": 0, "total": total}));
    for (i, (rel, path)) in files.iter().enumerate() {
        // Locking mid-upload stops the job instead of carrying on with
        // credentials the UI believes are gone.
        if state.conn.lock().await.is_none() {
            return Err("locked".into());
        }
        let fields = vec![("dir".to_string(), dest.clone()), ("rel".to_string(), rel.clone())];
        let r = upload_file(&c, &target, path, fields).await;
        let error = match &r {
            Ok(v) => {
                uploaded += 1;
                bytes += v.get("size").and_then(|s| s.as_u64()).unwrap_or(0);
                None
            }
            Err(e) => {
                failed.push(json!({"rel": rel, "error": e}));
                Some(e.clone())
            }
        };
        let _ = app.emit("folder-upload", json!({"job": job, "done": i + 1, "total": total, "rel": rel, "error": error}));
    }
    // Folders with no files in them would otherwise not exist on the box.
    for d in dirs {
        let has_file = files.iter().any(|(rel, _)| rel.starts_with(&format!("{d}/")));
        if has_file {
            continue;
        }
        let ok = match c
            .http
            .post(url(&c, "/box/fs/mkdir")?)
            .bearer_auth(&c.token)
            .timeout(Duration::from_secs(60))
            .json(&json!({"path": format!("{dest}/{d}")}))
            .send()
            .await
        {
            Ok(resp) => into_json(resp).await.is_ok(),
            Err(_) => false,
        };
        if !ok {
            failed.push(json!({"rel": format!("{d}/"), "error": "could not create folder"}));
        }
    }
    Ok(json!({"path": dest, "total": total, "uploaded": uploaded, "bytes": bytes, "failed": failed}))
}

/// Stream a box file (or zipped folder) to a local path.
#[tauri::command]
async fn download(remote_path: String, dest: String, state: State<'_, AppState>) -> Result<u64, String> {
    use tokio::io::AsyncWriteExt;
    let c = conn(&state).await?;
    let resp = c
        .http
        .get(url(&c, "/box/fs/download")?)
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
    let written: Result<u64, String> = async {
        let mut f = tokio::fs::File::create(&part).await.map_err(|e| e.to_string())?;
        let mut stream = resp.bytes_stream();
        let mut total = 0u64;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            total += chunk.len() as u64;
            f.write_all(&chunk).await.map_err(|e| e.to_string())?;
        }
        f.flush().await.map_err(|e| e.to_string())?;
        Ok(total)
    }
    .await;
    // A dropped connection used to leave a partial "<name>.part" behind.
    let total = match written {
        Ok(t) => t,
        Err(e) => {
            let _ = tokio::fs::remove_file(&part).await;
            return Err(e);
        }
    };
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
    // lock() may have drained the map between conn() above and the insert;
    // don't leave a live authenticated stream behind a locked UI.
    if state.conn.lock().await.is_none() {
        state.streams.lock().await.remove(&id);
        return Err("locked".into());
    }
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
                app.state::<AppState>().streams.lock().await.remove(&id);
                let _ = app.emit("ws", json!({"id": id, "closed": true, "error": e.to_string()}));
                return;
            }
            Err(_) => {
                app.state::<AppState>().streams.lock().await.remove(&id);
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
        // Streams that end on their own (server close, timeout) were never
        // removed from the map, so their senders accumulated for the app's life.
        app.state::<AppState>().streams.lock().await.remove(&id);
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
        .invoke_handler(tauri::generate_handler![unlock, lock, api, upload, upload_folder, download, ws_open, ws_send, ws_close])
        .run(tauri::generate_context!())
        .expect("error while running Helm");
}
