// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Windows service integration (install / uninstall / SCM entry point) plus the
// inbound-firewall rule. Windows-only; the rest of the program is portable.

use std::ffi::{OsStr, OsString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use windows_service::service::{
    ServiceAccess, ServiceControl, ServiceControlAccept, ServiceErrorControl, ServiceExitCode,
    ServiceInfo, ServiceStartType, ServiceState, ServiceStatus, ServiceType,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_dispatcher;
use windows_service::service_manager::{ServiceManager, ServiceManagerAccess};

use crate::config::{self, Config};

const SERVICE_NAME: &str = "SyslogCollector";
const DISPLAY_NAME: &str = "Syslog Collector";
const DESCRIPTION: &str =
    "Collects syslog (UDP/514) from network hosts into local log files and serves a local web viewer.";

windows_service::define_windows_service!(ffi_service_main, service_main);

/// Hand control to the SCM (called as `syslogd service`).
pub fn run_dispatcher() -> windows_service::Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
}

fn service_main(_args: Vec<OsString>) {
    if let Err(e) = run_service() {
        eprintln!("service failure: {e}");
    }
}

fn run_service() -> windows_service::Result<()> {
    let running = Arc::new(AtomicBool::new(true));
    let ctrl_flag = running.clone();

    let event_handler = move |control| match control {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            ctrl_flag.store(false, Ordering::SeqCst);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    };

    let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;
    status_handle.set_service_status(status(ServiceState::Running, ServiceControlAccept::STOP | ServiceControlAccept::SHUTDOWN))?;

    let cfg = Config::load(&config::config_path());
    crate::run_collector(cfg, running); // blocks until Stop

    status_handle.set_service_status(status(ServiceState::Stopped, ServiceControlAccept::empty()))?;
    Ok(())
}

fn status(state: ServiceState, accept: ServiceControlAccept) -> ServiceStatus {
    ServiceStatus {
        service_type: ServiceType::OWN_PROCESS,
        current_state: state,
        controls_accepted: accept,
        exit_code: ServiceExitCode::Win32(0),
        checkpoint: 0,
        wait_hint: Duration::default(),
        process_id: None,
    }
}

/// Create + auto-start the service, write default config (with chosen log dir),
/// and open the inbound firewall port. Requires elevation.
pub fn install(cfg: &Config) -> Result<(), Box<dyn std::error::Error>> {
    // Persist config so the service reads the same settings at boot.
    let cfg_path = config::config_path();
    if !cfg_path.exists() {
        cfg.save(&cfg_path)?;
    }
    std::fs::create_dir_all(&cfg.log_dir)?;

    let exe = std::env::current_exe()?;
    let manager = ServiceManager::local_computer(
        None::<&str>,
        ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
    )?;

    let info = ServiceInfo {
        name: OsString::from(SERVICE_NAME),
        display_name: OsString::from(DISPLAY_NAME),
        service_type: ServiceType::OWN_PROCESS,
        start_type: ServiceStartType::AutoStart, // starts at boot
        error_control: ServiceErrorControl::Normal,
        executable_path: exe,
        launch_arguments: vec![OsString::from("service")],
        dependencies: vec![],
        account_name: None, // LocalSystem
        account_password: None,
    };

    let service = manager.create_service(
        &info,
        ServiceAccess::CHANGE_CONFIG | ServiceAccess::START | ServiceAccess::QUERY_STATUS,
    )?;
    service.set_description(DESCRIPTION)?;
    service.start(&[] as &[&OsStr])?;

    // Auto-restart on unexpected exit (best-effort; sc.exe is always present).
    let _ = std::process::Command::new("sc")
        .args([
            "failure", SERVICE_NAME, "reset=", "86400",
            "actions=", "restart/5000/restart/5000/restart/60000",
        ])
        .status();

    open_firewall(cfg.udp_port)?;
    Ok(())
}

/// Stop + delete the service and remove the firewall rule. Requires elevation.
pub fn uninstall() -> Result<(), Box<dyn std::error::Error>> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
    let service = manager.open_service(
        SERVICE_NAME,
        ServiceAccess::STOP | ServiceAccess::DELETE | ServiceAccess::QUERY_STATUS,
    )?;

    // Best-effort stop; ignore "already stopped".
    if let Ok(st) = service.query_status() {
        if st.current_state != ServiceState::Stopped {
            let _ = service.stop();
            std::thread::sleep(Duration::from_secs(2));
        }
    }
    service.delete()?;
    // Remove the firewall rule for the port we actually configured.
    let port = Config::load(&config::config_path()).udp_port;
    close_firewall(port);
    Ok(())
}

fn firewall_rule_name(port: u16) -> String {
    format!("Syslog Collector UDP {port}")
}

fn open_firewall(port: u16) -> std::io::Result<()> {
    // netsh ships with Windows — no extra software, no extra dependency.
    let status = std::process::Command::new("netsh")
        .args([
            "advfirewall", "firewall", "add", "rule",
            &format!("name={}", firewall_rule_name(port)),
            "dir=in", "action=allow", "protocol=UDP",
            &format!("localport={port}"),
            "profile=any",
        ])
        .status()?;
    if !status.success() {
        eprintln!("[firewall] netsh add rule returned {status}; open UDP/{port} manually if needed.");
    }
    Ok(())
}

fn close_firewall(port: u16) {
    let _ = std::process::Command::new("netsh")
        .args([
            "advfirewall", "firewall", "delete", "rule",
            &format!("name={}", firewall_rule_name(port)),
        ])
        .status();
}
