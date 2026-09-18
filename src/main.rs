// Copyright (c) 2026 Tristan Conner <tristan@conner.house>
// SPDX-License-Identifier: MIT
//
// Just Syslog — a lean Windows syslog (UDP/514) receiver with a local web
// viewer, packaged as a Windows service. `run` works on any OS for testing.

mod config;
mod http;
mod store;
mod syslog;

#[cfg(windows)]
mod service;

use std::net::{TcpListener, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use config::Config;
use store::Cmd;
use syslog::{now_rfc3339, Message};

const VERSION: &str = env!("CARGO_PKG_VERSION");
const CHANNEL_CAP: usize = 10_000;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("help");

    match cmd {
        "run" => {
            let cfg = cfg_with_overrides(&args);
            eprintln!(
                "Just Syslog {VERSION}\n  UDP  : 0.0.0.0:{}\n  UI   : http://127.0.0.1:{}/\n  Logs : {}\nCtrl+C to stop.",
                cfg.udp_port, cfg.ui_port, cfg.log_dir.display()
            );
            let running = Arc::new(AtomicBool::new(true));
            run_collector(cfg, running);
        }
        "service" => {
            #[cfg(windows)]
            {
                if let Err(e) = service::run_dispatcher() {
                    eprintln!("service error: {e}");
                }
            }
            #[cfg(not(windows))]
            eprintln!("`service` mode is Windows-only. Use `run` for foreground testing.");
        }
        "install" => {
            #[cfg(windows)]
            {
                let cfg = cfg_with_overrides(&args);
                match service::install(&cfg) {
                    Ok(()) => println!("Installed and started service 'SyslogCollector'."),
                    Err(e) => eprintln!("install failed: {e}"),
                }
            }
            #[cfg(not(windows))]
            eprintln!("`install` is Windows-only.");
        }
        "uninstall" => {
            #[cfg(windows)]
            match service::uninstall() {
                Ok(()) => println!("Removed service 'SyslogCollector'."),
                Err(e) => eprintln!("uninstall failed: {e}"),
            }
            #[cfg(not(windows))]
            eprintln!("`uninstall` is Windows-only.");
        }
        "version" | "--version" | "-V" => println!("syslogd {VERSION}"),
        _ => print_usage(),
    }
}

fn print_usage() {
    println!(
        "Just Syslog {VERSION}\n\n\
         USAGE: syslogd <command> [options]\n\n\
         COMMANDS:\n\
         \x20 run                 Run in the foreground (any OS; for testing)\n\
         \x20 install             Install + start the Windows service (admin)\n\
         \x20 uninstall           Stop + remove the Windows service (admin)\n\
         \x20 service             Service entry point (invoked by Windows SCM)\n\
         \x20 version             Print version\n\n\
         OPTIONS (run/install):\n\
         \x20 --log-dir <path>    Folder for log files\n\
         \x20 --udp-port <n>      Syslog listen port (default 514)\n\
         \x20 --ui-port <n>       Local viewer port (default 8514)\n"
    );
}

fn cfg_with_overrides(args: &[String]) -> Config {
    let mut cfg = Config::load(&config::config_path());
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--log-dir" => {
                if let Some(v) = args.get(i + 1) {
                    cfg.log_dir = std::path::PathBuf::from(v);
                    i += 1;
                }
            }
            "--udp-port" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse().ok()) {
                    cfg.udp_port = v;
                    i += 1;
                }
            }
            "--ui-port" => {
                if let Some(v) = args.get(i + 1).and_then(|s| s.parse().ok()) {
                    cfg.ui_port = v;
                    i += 1;
                }
            }
            _ => {}
        }
        i += 1;
    }
    cfg
}

/// Wire up store + UDP receiver + HTTP viewer and block until `running` clears.
/// Called by both `run` (foreground) and the Windows service.
pub fn run_collector(cfg: Config, running: Arc<AtomicBool>) {
    // Bind sockets FIRST (UDP/514 is privileged on Unix), then drop root, then
    // start the workers — so nothing runs as root beyond the two binds.
    let udp_sock = match UdpSocket::bind(("0.0.0.0", cfg.udp_port)) {
        Ok(sock) => {
            sock.set_read_timeout(Some(Duration::from_secs(1))).ok();
            Some(sock)
        }
        Err(e) => {
            eprintln!("[udp] cannot bind 0.0.0.0:{} ({e}). UI still available.", cfg.udp_port);
            None
        }
    };
    let tcp_listener = match TcpListener::bind(("127.0.0.1", cfg.ui_port)) {
        Ok(listener) => Some(listener),
        Err(e) => {
            eprintln!("[ui] cannot bind 127.0.0.1:{} ({e}).", cfg.ui_port);
            None
        }
    };

    // Shed root now that the privileged port is bound. No-op unless we are root,
    // so foreground `run` and the Linux systemd unit (already a dedicated user)
    // are unaffected; the macOS root LaunchDaemon drops here.
    #[cfg(unix)]
    drop_privileges(&cfg.log_dir);

    let (cmd_tx, cmd_rx) = sync_channel::<Cmd>(CHANNEL_CAP);

    // Store owner thread.
    let (dir, mfm, rd, mtm) = (cfg.log_dir.clone(), cfg.max_file_mb, cfg.retention_days, cfg.max_total_mb);
    let store_h = thread::spawn(move || store::run(dir, mfm, rd, mtm, cmd_rx, 600));

    // UDP syslog receiver (all interfaces, through the firewall).
    let udp_h = udp_sock.map(|sock| {
        let tx = cmd_tx.clone();
        let run = running.clone();
        thread::spawn(move || udp_loop(sock, tx, run))
    });

    // Local web viewer (loopback only).
    let http_h = tcp_listener.map(|listener| {
        let tx = cmd_tx.clone();
        let run = running.clone();
        let c = cfg.clone();
        thread::spawn(move || http::serve(listener, c, tx, run))
    });

    // Block until stop is requested.
    while running.load(Ordering::Relaxed) {
        thread::sleep(Duration::from_millis(500));
    }

    // Drain and shut down: worker loops exit within ~1s (socket timeouts).
    if let Some(h) = udp_h {
        let _ = h.join();
    }
    if let Some(h) = http_h {
        let _ = h.join();
    }
    drop(cmd_tx); // closes the store channel so it can finish
    let _ = store_h.join();
}

/// Drop root to a dedicated service account after the privileged UDP port is
/// bound. No-op unless running as root, so foreground `run` and the Linux
/// systemd unit (already a dedicated user) are unaffected — only the macOS root
/// LaunchDaemon actually drops. Fails OPEN to root when the account or a chowned
/// log dir is missing (so collection keeps working on a partial install), but
/// fails CLOSED (exits) if a drop leaves root regainable.
#[cfg(unix)]
fn drop_privileges(log_dir: &std::path::Path) {
    use std::os::unix::fs::MetadataExt;

    if unsafe { libc::geteuid() } != 0 {
        return; // not root: nothing to drop
    }
    let user = if cfg!(target_os = "macos") { "_syslogcollector" } else { "syslog-collector" };
    let Ok(cuser) = std::ffi::CString::new(user) else { return };
    let pw = unsafe { libc::getpwnam(cuser.as_ptr()) };
    if pw.is_null() {
        eprintln!("[priv] service account '{user}' not found; staying root");
        return;
    }
    let (uid, gid) = unsafe { ((*pw).pw_uid, (*pw).pw_gid) };

    // Self-gate: only drop when the installer already chowned the log dir to the
    // account. Otherwise the dropped process couldn't write logs, so staying root
    // is the safer, still-functional choice.
    match std::fs::metadata(log_dir) {
        Ok(m) if m.uid() == uid => {}
        _ => {
            eprintln!("[priv] {} not owned by '{user}'; staying root", log_dir.display());
            return;
        }
    }

    // Order matters: set group + supplementary groups BEFORE uid (once root is
    // gone, setgid/initgroups would fail).
    unsafe {
        if libc::setgid(gid) != 0 {
            eprintln!("[priv] setgid failed; staying root");
            return;
        }
        libc::initgroups(cuser.as_ptr(), gid as _);
        if libc::setuid(uid) != 0 {
            eprintln!("[priv] setuid failed; staying root");
            return;
        }
    }
    // A correct drop must make root unregainable; if not, fail closed.
    if unsafe { libc::seteuid(0) } == 0 {
        eprintln!("[priv] FATAL: root regainable after drop; exiting");
        std::process::exit(1);
    }
    eprintln!("[priv] dropped privileges to '{user}' (uid {uid})");
}

fn udp_loop(sock: UdpSocket, tx: std::sync::mpsc::SyncSender<Cmd>, running: Arc<AtomicBool>) {
    let mut buf = vec![0u8; 65_535]; // max UDP payload
    while running.load(Ordering::Relaxed) {
        match sock.recv_from(&mut buf) {
            Ok((n, addr)) if n > 0 => {
                let ip = addr.ip().to_string();
                let recv = now_rfc3339();
                // A parser panic on hostile input must never kill the receiver
                // thread (that would silently stop all collection). Catch it,
                // drop the one datagram, keep receiving.
                let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    Message::parse(&buf[..n], &ip, &recv)
                }));
                match parsed {
                    // Drop on overflow rather than block the receiver under flood;
                    // the queue is bounded (10k), so a burst sheds load here.
                    Ok(m) => { let _ = tx.try_send(Cmd::Msg(m)); }
                    Err(_) => eprintln!("dropped datagram from {ip}: parser panicked"),
                }
            }
            Ok(_) => {}
            Err(ref e) if is_timeout(e) => {} // expected: 1s poll to check `running`
            Err(_) => thread::sleep(Duration::from_millis(100)),
        }
    }
}

fn is_timeout(e: &std::io::Error) -> bool {
    matches!(
        e.kind(),
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
    )
}

#[cfg(all(test, unix))]
mod tests {
    #[test]
    fn drop_privileges_noop_when_not_root() {
        // As a normal user (or as root without the service account / a matching
        // log-dir owner) this must return without dropping or exiting.
        super::drop_privileges(std::path::Path::new("/nonexistent-just-syslog"));
    }
}
