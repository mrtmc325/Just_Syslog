// Copyright (c) 2026 Tristan Conner <tristan@conner.house>. All rights reserved.
//
// Menu bar controller for the Syslog Collector service (macOS). Reads live
// status from the collector's loopback HTTP API (no privilege needed) and
// controls the root launchd daemon via `launchctl` behind a macOS admin prompt.
// AppKit + Foundation only — no third-party dependencies.

import AppKit
import Foundation

let DAEMON_LABEL = "house.conner.syslog-collector"
let PLIST_PATH = "/Library/LaunchDaemons/\(DAEMON_LABEL).plist"
let CONFIG_PATH = "/etc/syslog-collector/config.txt"

// Ordered config fields shown in the Configuration window.
let FIELD_DEFS: [(label: String, key: String)] = [
    ("Log directory", "log_dir"),
    ("Syslog UDP port", "udp_port"),
    ("Viewer port", "ui_port"),
    ("Max file size (MB)", "max_file_mb"),
    ("Retention (days)", "retention_days"),
    ("Max total size (MB)", "max_total_mb"),
]

struct Config {
    var values: [String: String] = [
        "log_dir": "/var/log/syslog-collector",
        "udp_port": "514",
        "ui_port": "8514",
        "max_file_mb": "100",
        "retention_days": "30",
        "max_total_mb": "2048",
    ]

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOfFile: CONFIG_PATH, encoding: .utf8) else { return c }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if c.values[k] != nil { c.values[k] = v }
        }
        return c
    }

    func serialize() -> String {
        var out = "# Syslog Collector configuration (macOS / Linux)\n"
        for def in FIELD_DEFS {
            out += "\(def.key)=\(values[def.key] ?? "")\n"
        }
        return out
    }

    var uiPort: String { values["ui_port"] ?? "8514" }
    var logDir: String { values["log_dir"] ?? "/var/log/syslog-collector" }
}

/// Run a shell command as root via one macOS authorization prompt. Returns true
/// on success. Credentials are cached by the OS for ~5 min, so back-to-back
/// actions usually prompt once.
@discardableResult
func runPrivileged(_ shell: String) -> Bool {
    let esc = shell
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(esc)\" with administrator privileges"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
    catch { return false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var running = false
    var messages = 0
    var cfg = Config.load()

    // Menu items kept for live updates (built once, no rebuild-while-open jank).
    let headerItem = NSMenuItem(title: "Checking…", action: nil, keyEquivalent: "")
    var viewerItem: NSMenuItem!
    var toggleItem: NSMenuItem!

    // Config window
    var win: NSWindow?
    var fields: [String: NSTextField] = [:]

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "dot.radiowaves.left.and.right",
                          accessibilityDescription: "Syslog Collector")
        img?.isTemplate = true
        statusItem.button?.image = img

        let menu = NSMenu()
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(.separator())
        viewerItem = item("Open Viewer", #selector(openViewer))
        menu.addItem(viewerItem)
        menu.addItem(item("Configuration…", #selector(showConfig)))
        toggleItem = item("Start Service", #selector(toggleService))
        menu.addItem(toggleItem)
        menu.addItem(item("Clear Logs…", #selector(clearLogs)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit)))
        statusItem.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func applyState() {
        statusItem.button?.appearsDisabled = !running
        headerItem.title = running ? "Running — \(messages) messages" : "Stopped"
        viewerItem.isHidden = !running
        toggleItem.title = running ? "Stop Service" : "Start Service"
    }

    func refresh() {
        cfg = Config.load()
        guard let url = URL(string: "http://127.0.0.1:\(cfg.uiPort)/api/stats") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }
            var up = false
            var msgs = 0
            if err == nil, let d = data,
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                up = true
                if let m = obj["total_messages"] as? Int { msgs = m }
            }
            DispatchQueue.main.async {
                self.running = up
                self.messages = msgs
                self.applyState()
            }
        }.resume()
    }

    @objc func openViewer() {
        if let u = URL(string: "http://127.0.0.1:\(cfg.uiPort)/") { NSWorkspace.shared.open(u) }
    }

    @objc func toggleService() {
        let wasRunning = running
        DispatchQueue.global().async {
            if wasRunning {
                _ = runPrivileged("launchctl bootout system \(PLIST_PATH) 2>/dev/null || launchctl bootout system/\(DAEMON_LABEL)")
            } else {
                _ = runPrivileged("launchctl bootstrap system \(PLIST_PATH) 2>/dev/null || launchctl kickstart system/\(DAEMON_LABEL)")
            }
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func clearLogs() {
        let a = NSAlert()
        a.messageText = "Clear all collected logs?"
        a.informativeText = "Deletes every .jsonl file in \(cfg.logDir) and restarts the collector."
        a.addButton(withTitle: "Clear")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let dir = cfg.logDir
        DispatchQueue.global().async {
            _ = runPrivileged("rm -f '\(dir)'/*.jsonl 2>/dev/null; launchctl kickstart -k system/\(DAEMON_LABEL) 2>/dev/null || true")
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func showConfig() {
        cfg = Config.load()
        if win == nil { buildConfigWindow() }
        for def in FIELD_DEFS { fields[def.key]?.stringValue = cfg.values[def.key] ?? "" }
        win?.center()
        NSApp.activate(ignoringOtherApps: true)
        win?.makeKeyAndOrderFront(nil)
    }

    func buildConfigWindow() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        for def in FIELD_DEFS {
            let label = NSTextField(labelWithString: def.label)
            let field = NSTextField(string: "")
            field.widthAnchor.constraint(equalToConstant: 230).isActive = true
            fields[def.key] = field
            grid.addRow(with: [label, field])
        }
        grid.column(at: 0).xPlacement = .trailing

        let save = NSButton(title: "Save & Restart", target: self, action: #selector(saveConfig))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeConfig))
        let buttons = NSStackView(views: [cancel, save])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.spacing = 10

        let root = NSView()
        root.addSubview(grid)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Syslog Collector Configuration"
        w.isReleasedWhenClosed = false
        w.contentView = root
        win = w
    }

    @objc func saveConfig() {
        var newCfg = cfg
        for def in FIELD_DEFS {
            newCfg.values[def.key] = fields[def.key]?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        }
        let tmp = NSTemporaryDirectory() + "syslog-collector-\(UUID().uuidString).txt"
        guard (try? newCfg.serialize().write(toFile: tmp, atomically: true, encoding: .utf8)) != nil else { return }
        win?.orderOut(nil)
        DispatchQueue.global().async {
            _ = runPrivileged("mkdir -p /etc/syslog-collector; cp '\(tmp)' '\(CONFIG_PATH)'; rm -f '\(tmp)'; launchctl kickstart -k system/\(DAEMON_LABEL) 2>/dev/null || true")
            DispatchQueue.main.async { self.refresh() }
        }
    }

    @objc func closeConfig() { win?.orderOut(nil) }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
