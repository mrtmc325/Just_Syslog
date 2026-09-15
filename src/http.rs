// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Minimal HTTP/1.1 server for the local viewer. Loopback-only, single user, so
// a small std-only handler beats pulling in a web framework. GET for reads,
// POST for the one mutating route (cleanup). Every request is bounded and the
// file parameter is validated against the store's allow-list.

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, SyncSender};
use std::sync::Arc;
use std::time::Duration;

use crate::config::Config;
use crate::store::{self, Cmd};

const INDEX_HTML: &str = include_str!("web/index.html");
const MAX_HEADER: usize = 8 * 1024;

pub fn serve(
    listener: TcpListener,
    cfg: Config,
    cmd_tx: SyncSender<Cmd>,
    running: Arc<AtomicBool>,
) {
    // Poll-accept so the loop notices shutdown promptly (see accept_iter).
    for stream in accept_iter(&listener, &running) {
        if !running.load(Ordering::Relaxed) {
            break;
        }
        let Ok(stream) = stream else { continue };
        let cfg = cfg.clone();
        let tx = cmd_tx.clone();
        std::thread::spawn(move || {
            let _ = handle(stream, &cfg, &tx);
        });
    }
}

fn accept_iter<'a>(
    listener: &'a TcpListener,
    running: &'a Arc<AtomicBool>,
) -> impl Iterator<Item = std::io::Result<TcpStream>> + 'a {
    listener.set_nonblocking(true).ok();
    std::iter::from_fn(move || {
        loop {
            if !running.load(Ordering::Relaxed) {
                return None;
            }
            match listener.accept() {
                Ok((s, _)) => return Some(Ok(s)),
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(200));
                }
                Err(e) => return Some(Err(e)),
            }
        }
    })
}

fn handle(mut stream: TcpStream, cfg: &Config, tx: &SyncSender<Cmd>) -> std::io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    stream.set_write_timeout(Some(Duration::from_secs(10)))?;

    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    let mut n = reader.read_line(&mut request_line)?;
    if n == 0 {
        return Ok(());
    }
    // Drain headers (bounded).
    let mut header_bytes = request_line.len();
    loop {
        let mut line = String::new();
        n = reader.read_line(&mut line)?;
        header_bytes += n;
        if n == 0 || line == "\r\n" || line == "\n" || header_bytes > MAX_HEADER {
            break;
        }
    }

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("/");
    let (path, query) = target.split_once('?').unwrap_or((target, ""));

    match (method, path) {
        ("GET", "/") | ("GET", "/index.html") => {
            respond(&mut stream, 200, "text/html; charset=utf-8", INDEX_HTML.as_bytes())
        }
        ("GET", "/api/files") => {
            let names = store::list_log_names(&cfg.log_dir);
            let mut body = String::from("[");
            for (i, nm) in names.iter().enumerate() {
                if i > 0 {
                    body.push(',');
                }
                body.push('"');
                body.push_str(&crate::syslog::json_escape(nm));
                body.push('"');
            }
            body.push(']');
            respond(&mut stream, 200, "application/json", body.as_bytes())
        }
        ("GET", "/api/messages") => {
            let file = query_get(query, "file").unwrap_or_default();
            let limit = query_get(query, "limit")
                .and_then(|v| v.parse::<usize>().ok())
                .unwrap_or(500)
                .min(5000);
            let file = if file.is_empty() {
                store::list_log_names(&cfg.log_dir).into_iter().next().unwrap_or_default()
            } else {
                url_decode(&file)
            };
            let body = store::read_messages_json(&cfg.log_dir, &file, limit)
                .unwrap_or_else(|_| "[]".into());
            respond(&mut stream, 200, "application/json", body.as_bytes())
        }
        ("GET", "/api/config") => {
            respond(&mut stream, 200, "application/json", cfg.to_json().as_bytes())
        }
        ("GET", "/api/stats") => {
            let (r_tx, r_rx) = sync_channel(1);
            let body = if tx.send(Cmd::Stats(r_tx)).is_ok() {
                match r_rx.recv_timeout(Duration::from_secs(5)) {
                    Ok(s) => format!(
                        "{{\"total_messages\":{},\"total_bytes\":{},\"file_count\":{},\"current_file\":\"{}\"}}",
                        s.total_messages, s.total_bytes, s.file_count,
                        crate::syslog::json_escape(&s.current_file)
                    ),
                    Err(_) => "{}".into(),
                }
            } else {
                "{}".into()
            };
            respond(&mut stream, 200, "application/json", body.as_bytes())
        }
        ("POST", "/api/cleanup") => {
            let (r_tx, r_rx) = sync_channel(1);
            let body = if tx.send(Cmd::Cleanup(r_tx)).is_ok() {
                match r_rx.recv_timeout(Duration::from_secs(30)) {
                    Ok(s) => format!(
                        "{{\"files_deleted\":{},\"bytes_freed\":{}}}",
                        s.files_deleted, s.bytes_freed
                    ),
                    Err(_) => "{\"files_deleted\":0,\"bytes_freed\":0}".into(),
                }
            } else {
                "{\"files_deleted\":0,\"bytes_freed\":0}".into()
            };
            respond(&mut stream, 200, "application/json", body.as_bytes())
        }
        ("GET", _) => respond(&mut stream, 404, "text/plain", b"not found"),
        _ => respond(&mut stream, 405, "text/plain", b"method not allowed"),
    }
}

fn respond(stream: &mut TcpStream, code: u16, ctype: &str, body: &[u8]) -> std::io::Result<()> {
    let reason = match code {
        200 => "OK",
        404 => "Not Found",
        405 => "Method Not Allowed",
        _ => "OK",
    };
    // Loopback single-user UI: no auth, but lock the browser down defensively.
    let head = format!(
        "HTTP/1.1 {code} {reason}\r\n\
         Content-Type: {ctype}\r\n\
         Content-Length: {}\r\n\
         X-Content-Type-Options: nosniff\r\n\
         Content-Security-Policy: default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'\r\n\
         Cache-Control: no-store\r\n\
         Connection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}

fn query_get(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        if k == key {
            Some(v.to_string())
        } else {
            None
        }
    })
}

/// Minimal percent-decoding for the `file` query value (also '+' -> space).
fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'%' if i + 2 < b.len() => {
                let hi = hex(b[i + 1]);
                let lo = hex(b[i + 2]);
                if let (Some(h), Some(l)) = (hi, lo) {
                    out.push(h * 16 + l);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            c => {
                out.push(c);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

fn hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn query_and_decode() {
        assert_eq!(query_get("file=a&limit=10", "limit").as_deref(), Some("10"));
        assert_eq!(query_get("file=a", "missing"), None);
        assert_eq!(url_decode("syslog-20260915%2D3.jsonl"), "syslog-20260915-3.jsonl");
        assert_eq!(url_decode("a+b"), "a b");
    }
}
