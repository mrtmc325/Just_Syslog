// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Plain key=value config. No TOML/serde dependency — the shape is five keys.

use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Config {
    pub log_dir: PathBuf,
    pub udp_port: u16,
    pub ui_port: u16,
    pub max_file_mb: u64,   // rotate active file past this size
    pub retention_days: u64, // delete files older than this (0 = never)
    pub max_total_mb: u64,  // delete oldest until dir is under this (0 = no cap)
}

impl Default for Config {
    fn default() -> Self {
        Config {
            log_dir: default_log_dir(),
            udp_port: 514,
            ui_port: 8514,
            max_file_mb: 100,
            retention_days: 30,
            max_total_mb: 2048,
        }
    }
}

impl Config {
    pub fn load(path: &Path) -> Config {
        let mut c = Config::default();
        let Ok(text) = fs::read_to_string(path) else { return c };
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((k, v)) = line.split_once('=') else { continue };
            let (k, v) = (k.trim(), v.trim());
            match k {
                "log_dir" => c.log_dir = PathBuf::from(v),
                "udp_port" => c.udp_port = v.parse().unwrap_or(c.udp_port),
                "ui_port" => c.ui_port = v.parse().unwrap_or(c.ui_port),
                "max_file_mb" => c.max_file_mb = v.parse().unwrap_or(c.max_file_mb),
                "retention_days" => c.retention_days = v.parse().unwrap_or(c.retention_days),
                "max_total_mb" => c.max_total_mb = v.parse().unwrap_or(c.max_total_mb),
                _ => {}
            }
        }
        c
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let body = format!(
            "# Syslog Collector configuration\n\
             log_dir={}\n\
             udp_port={}\n\
             ui_port={}\n\
             max_file_mb={}\n\
             retention_days={}\n\
             max_total_mb={}\n",
            self.log_dir.display(), self.udp_port, self.ui_port,
            self.max_file_mb, self.retention_days, self.max_total_mb,
        );
        fs::write(path, body)
    }

    pub fn to_json(&self) -> String {
        format!(
            "{{\"log_dir\":\"{}\",\"udp_port\":{},\"ui_port\":{},\"max_file_mb\":{},\"retention_days\":{},\"max_total_mb\":{}}}",
            crate::syslog::json_escape(&self.log_dir.display().to_string()),
            self.udp_port, self.ui_port, self.max_file_mb,
            self.retention_days, self.max_total_mb,
        )
    }
}

/// Config file: `%ProgramData%\SyslogCollector\config.txt` on Windows,
/// `/etc/syslog-collector/config.txt` on macOS/Linux.
pub fn config_path() -> PathBuf {
    #[cfg(windows)]
    {
        windows_base().join("config.txt")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/etc/syslog-collector/config.txt")
    }
}

/// Default logs: `%ProgramData%\SyslogCollector\logs` on Windows,
/// `/var/log/syslog-collector` on macOS/Linux.
fn default_log_dir() -> PathBuf {
    #[cfg(windows)]
    {
        windows_base().join("logs")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/var/log/syslog-collector")
    }
}

#[cfg(windows)]
fn windows_base() -> PathBuf {
    std::env::var("ProgramData")
        .map(|pd| PathBuf::from(pd).join("SyslogCollector"))
        .unwrap_or_else(|_| PathBuf::from(".").join("syslog-collector-data"))
}
