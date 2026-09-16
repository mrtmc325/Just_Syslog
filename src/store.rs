// Copyright (c) 2026 Tristan Conner <tristan@conner.house>
// SPDX-License-Identifier: MIT
//
// Single-owner log store. One thread owns all file handles, so there are no
// write races and the active file is never deleted by cleanup. Records are
// JSON-lines: one Message per line. The file is created only after the first
// message arrives (per requirement).

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender};
use std::time::Duration;

use crate::syslog::{now_rfc3339, Message};

pub enum Cmd {
    Msg(Message),
    Cleanup(SyncSender<CleanupStats>),
    Stats(SyncSender<StoreStats>),
}

#[derive(Default)]
pub struct CleanupStats {
    pub files_deleted: u64,
    pub bytes_freed: u64,
}

#[derive(Default)]
pub struct StoreStats {
    pub total_messages: u64,
    pub total_bytes: u64,
    pub file_count: u64,
    pub current_file: String,
}

struct Store {
    dir: PathBuf,
    max_file_bytes: u64,
    retention_days: u64,
    max_total_bytes: u64,
    file: Option<File>,
    current_day: String,
    current_name: String,
    current_size: u64,
    messages_written: u64,
}

impl Store {
    fn append(&mut self, m: &Message) -> io::Result<()> {
        self.ensure_open()?;
        let mut line = m.to_json();
        line.push('\n');
        let bytes = line.as_bytes();
        // Rotate first if this write would push us over the cap.
        if self.current_size + bytes.len() as u64 > self.max_file_bytes && self.current_size > 0 {
            self.rotate()?;
        }
        let f = self.file.as_mut().expect("open");
        f.write_all(bytes)?;
        f.flush()?; // durability over throughput — syslog volume is modest.
        // Per-write flush; batch on a timer only if a busy site needs it.
        self.current_size += bytes.len() as u64;
        self.messages_written += 1;
        Ok(())
    }

    fn ensure_open(&mut self) -> io::Result<()> {
        let want = daily_name(&now_rfc3339());
        // Guard on the day (not the filename) so the cached handle is reused;
        // rotate() keeps current_day, so a mid-day rotation still short-circuits.
        if self.file.is_some() && self.current_day == want {
            return Ok(());
        }
        fs::create_dir_all(&self.dir)?;
        // Continue the day's highest existing file so restarts don't fragment.
        let (name, path, size) = find_current(&self.dir, &want);
        let f = OpenOptions::new().create(true).append(true).open(&path)?;
        self.file = Some(f);
        self.current_day = want;
        self.current_name = name;
        self.current_size = size;
        Ok(())
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file = None;
        let base = daily_name(&now_rfc3339());
        let (name, path) = new_after(&self.dir, &base);
        let f = OpenOptions::new().create(true).append(true).open(&path)?;
        self.file = Some(f);
        self.current_name = name;
        self.current_size = 0;
        Ok(())
    }

    fn cleanup(&mut self) -> CleanupStats {
        let mut stats = CleanupStats::default();
        let mut files = match list_logs(&self.dir) {
            Ok(f) => f,
            Err(_) => return stats,
        };
        let now = std::time::SystemTime::now();
        let keep_secs = self.retention_days.saturating_mul(86_400);

        // 1) Age-based retention.
        if self.retention_days > 0 {
            files.retain(|(name, path, size, mtime)| {
                if name == &self.current_name {
                    return true; // never touch the active file
                }
                let age = now.duration_since(*mtime).unwrap_or_default().as_secs();
                if age > keep_secs {
                    if fs::remove_file(path).is_ok() {
                        stats.files_deleted += 1;
                        stats.bytes_freed += size;
                    }
                    false
                } else {
                    true
                }
            });
        }

        // 2) Total-size cap: drop oldest survivors until under budget.
        if self.max_total_bytes > 0 {
            let mut total: u64 = files.iter().map(|f| f.2).sum();
            // oldest first
            files.sort_by_key(|f| f.3);
            for (name, path, size, _) in &files {
                if total <= self.max_total_bytes {
                    break;
                }
                if name == &self.current_name {
                    continue;
                }
                if fs::remove_file(path).is_ok() {
                    stats.files_deleted += 1;
                    stats.bytes_freed += size;
                    total = total.saturating_sub(*size);
                }
            }
        }
        stats
    }

    fn stats(&self) -> StoreStats {
        let mut s = StoreStats {
            current_file: self.current_name.clone(),
            ..Default::default()
        };
        if let Ok(files) = list_logs(&self.dir) {
            s.file_count = files.len() as u64;
            s.total_bytes = files.iter().map(|f| f.2).sum();
        }
        s.total_messages = self.messages_written;
        s
    }
}

fn daily_name(rfc3339: &str) -> String {
    // "2026-09-15T..." -> "syslog-20260915"
    let d: String = rfc3339.chars().take(10).filter(|c| *c != '-').collect();
    format!("syslog-{d}")
}

/// Highest existing file for `base` (to continue appending), or "<base>.jsonl"
/// with size 0 if none exists yet. Indices are contiguous (rotate fills gaps).
fn find_current(dir: &Path, base: &str) -> (String, PathBuf, u64) {
    let first = format!("{base}.jsonl");
    let fp = dir.join(&first);
    let Ok(md) = fs::metadata(&fp) else {
        return (first, fp, 0);
    };
    let mut best = (first, fp, md.len());
    let mut n = 1;
    loop {
        let cand = format!("{base}-{n}.jsonl");
        let cp = dir.join(&cand);
        match fs::metadata(&cp) {
            Ok(md) => {
                best = (cand, cp, md.len());
                n += 1;
            }
            Err(_) => break,
        }
    }
    best
}

/// The next free file beyond the highest existing index for `base`.
fn new_after(dir: &Path, base: &str) -> (String, PathBuf) {
    let first = format!("{base}.jsonl");
    if !dir.join(&first).exists() {
        return (first.clone(), dir.join(first));
    }
    let mut n = 1;
    loop {
        let cand = format!("{base}-{n}.jsonl");
        let cp = dir.join(&cand);
        if !cp.exists() {
            return (cand, cp);
        }
        n += 1;
    }
}

type LogEntry = (String, PathBuf, u64, std::time::SystemTime);

fn list_logs(dir: &Path) -> io::Result<Vec<LogEntry>> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if is_log_name(&name) {
            let md = entry.metadata()?;
            let mtime = md.modified().unwrap_or(std::time::UNIX_EPOCH);
            out.push((name, entry.path(), md.len(), mtime));
        }
    }
    Ok(out)
}

/// Strict allow-list for log filenames — also the path-traversal guard used by
/// the HTTP layer. Only "syslog-YYYYMMDD.jsonl" / "syslog-YYYYMMDD-N.jsonl".
pub fn is_log_name(name: &str) -> bool {
    let Some(stem) = name.strip_suffix(".jsonl") else { return false };
    let Some(rest) = stem.strip_prefix("syslog-") else { return false };
    let (date, idx) = match rest.split_once('-') {
        Some((d, i)) => (d, Some(i)),
        None => (rest, None),
    };
    if date.len() != 8 || !date.bytes().all(|b| b.is_ascii_digit()) {
        return false;
    }
    match idx {
        None => true,
        Some(i) => !i.is_empty() && i.bytes().all(|b| b.is_ascii_digit()),
    }
}

/// Sorted (desc) list of log file names for the UI dropdown.
pub fn list_log_names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = list_logs(dir)
        .unwrap_or_default()
        .into_iter()
        .map(|f| f.0)
        .collect();
    names.sort();
    names.reverse();
    names
}

/// Return up to `limit` most-recent records from `name`, as a JSON array. Each
/// stored line is already a JSON object, so we concatenate without re-parsing.
/// Reads only the file tail to bound memory regardless of file size.
pub fn read_messages_json(dir: &Path, name: &str, limit: usize) -> io::Result<String> {
    if !is_log_name(name) {
        return Ok("[]".into()); // reject anything not on the allow-list
    }
    let path = dir.join(name);
    let mut f = File::open(&path)?;
    let len = f.metadata()?.len();
    const TAIL: u64 = 2 * 1024 * 1024; // 2 MiB window
    let start = len.saturating_sub(TAIL);
    f.seek(SeekFrom::Start(start))?;
    let mut buf = Vec::new();
    f.read_to_end(&mut buf)?;
    let text = String::from_utf8_lossy(&buf);
    let mut lines: Vec<&str> = text.lines().collect();
    if start > 0 && !lines.is_empty() {
        lines.remove(0); // drop partial first line from the tail cut
    }
    // Tail-scan, O(window). Add an index only if huge files need paging.
    let take = lines.len().min(limit);
    let body = lines[lines.len() - take..]
        .iter()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(",");
    Ok(format!("[{body}]"))
}

/// Run the store on the current thread until the command channel closes.
/// `auto_cleanup_secs` also drives periodic retention while idle.
pub fn run(
    dir: PathBuf,
    max_file_mb: u64,
    retention_days: u64,
    max_total_mb: u64,
    rx: Receiver<Cmd>,
    auto_cleanup_secs: u64,
) {
    let mut store = Store {
        dir,
        max_file_bytes: max_file_mb.max(1) * 1024 * 1024,
        retention_days,
        max_total_bytes: max_total_mb * 1024 * 1024,
        file: None,
        current_day: String::new(),
        current_name: String::new(),
        current_size: 0,
        messages_written: 0,
    };
    let idle = Duration::from_secs(auto_cleanup_secs.max(30));
    let mut last_cleanup = std::time::Instant::now();
    loop {
        match rx.recv_timeout(idle) {
            Ok(Cmd::Msg(m)) => {
                if let Err(e) = store.append(&m) {
                    eprintln!("[store] write error: {e}");
                }
                // recv_timeout never fires under steady traffic, so also run
                // retention on an elapsed check after appends.
                if last_cleanup.elapsed() >= idle {
                    store.cleanup();
                    last_cleanup = std::time::Instant::now();
                }
            }
            Ok(Cmd::Cleanup(reply)) => {
                let _ = reply.send(store.cleanup());
                last_cleanup = std::time::Instant::now();
            }
            Ok(Cmd::Stats(reply)) => {
                let _ = reply.send(store.stats());
            }
            Err(RecvTimeoutError::Timeout) => {
                store.cleanup(); // periodic automatic GC while idle
                last_cleanup = std::time::Instant::now();
            }
            Err(RecvTimeoutError::Disconnected) => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log_name_allowlist() {
        assert!(is_log_name("syslog-20260915.jsonl"));
        assert!(is_log_name("syslog-20260915-3.jsonl"));
        assert!(!is_log_name("syslog-2026091.jsonl")); // 7 digits
        assert!(!is_log_name("syslog-20260915.txt"));
        assert!(!is_log_name("../etc/passwd"));
        assert!(!is_log_name("syslog-20260915-.jsonl"));
        assert!(!is_log_name("evil-20260915.jsonl"));
        assert!(!is_log_name("syslog-2026091x.jsonl"));
    }

    #[test]
    fn daily_name_from_ts() {
        assert_eq!(daily_name("2026-09-15T18:00:00Z"), "syslog-20260915");
    }

    #[test]
    fn append_creates_and_reads_back() {
        let dir = std::env::temp_dir().join(format!("sc-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut s = Store {
            dir: dir.clone(),
            max_file_bytes: 1024 * 1024,
            retention_days: 30,
            max_total_bytes: 0,
            file: None,
            current_day: String::new(),
            current_name: String::new(),
            current_size: 0,
            messages_written: 0,
        };
        assert!(!dir.exists()); // nothing until first message
        let m = Message::parse(b"<13>hello world", "10.0.0.1", &now_rfc3339());
        s.append(&m).unwrap();
        assert!(dir.exists());
        let names = list_log_names(&dir);
        assert_eq!(names.len(), 1);
        let json = read_messages_json(&dir, &names[0], 100).unwrap();
        assert!(json.contains("hello world"));
        assert!(json.starts_with('[') && json.ends_with(']'));
        let _ = fs::remove_dir_all(&dir);
    }
}
