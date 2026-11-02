import AppKit
import CoreGraphics
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var server: HTTPServer!
    private var iconTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let cfg = Config.shared

        // Menu bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "key.viewfinder", accessibilityDescription: "Nodlock")
            button.image?.isTemplate = true
            button.title = ""
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Start subsystems.
        startWatcher()
        Health.shared.start()
        server = HTTPServer(host: cfg.bind, port: cfg.port)
        do {
            try server.start()
            FileHandle.standardError.write(Data(
                "nodlock: panel on http://\(cfg.bind):\(cfg.port) (expose: tailscale serve --bg \(cfg.port))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("nodlock: failed to bind \(cfg.bind):\(cfg.port): \(error)\n".utf8))
        }

        // Reflect prompt and health state in the menu bar icon.
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
        RunLoop.main.add(iconTimer!, forMode: .common)

        maybeAutoOpenOnboarding()
    }

    // Auto-open the wizard for a brand-new user who has not finished setup and
    // is still missing a core permission. The "didCompleteOnboarding" flag stops
    // it nagging once the user clicked Finish. Setup… stays in the menu regardless.
    private func maybeAutoOpenOnboarding() {
        let completed = UserDefaults.standard.bool(forKey: "didCompleteOnboarding")
        let permsOK = CGPreflightScreenCaptureAccess() && AXIsProcessTrusted()
        guard !completed && !permsOK else { return }
        DispatchQueue.main.async {
            OnboardingWindowController.shared.show()
        }
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        // Red = a prompt waits, orange = a health watch is down, else the plain template glyph.
        let down = ((Health.shared.snapshot()["summary"] as? [String: Int])?["down"] ?? 0) > 0
        let tint: NSColor? = AppState.shared.dialog != nil ? .systemRed : down ? .systemOrange : nil
        var image = NSImage(systemSymbolName: "key.viewfinder", accessibilityDescription: "Nodlock")
        if let tint = tint { image = image?.withSymbolConfiguration(.init(paletteColors: [tint])) }
        image?.isTemplate = tint == nil
        button.image = image
    }

    // Rebuild the menu on each open so status/VPN/permissions are live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AppState.shared
        let d = state.dialog

        // Status line: prompt owner, or "Watching" plus uptime and pushes in grey.
        let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        if let d = d {
            statusItem.attributedTitle = NSAttributedString(
                string: "PROMPT ACTIVE: \(d.owner)",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        } else {
            let mins = state.uptime / 60
            let up = mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m"
            let pushes = state.pushes == 1 ? "1 push" : "\(state.pushes) pushes"
            statusItem.attributedTitle = titled("Watching for prompts", secondary: "\(up) · \(pushes)")
        }
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(healthItem())

        // Network: works like the Wi-Fi menu. Check = active, click = switch.
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Network"))
        let (tsUp, tsIP) = tailscaleState()
        let ts = NSMenuItem(title: "Tailscale", action: #selector(switchTailscale), keyEquivalent: "")
        ts.target = self
        ts.state = tsUp ? .on : .off
        if !tsIP.isEmpty { ts.attributedTitle = titled("Tailscale", secondary: tsIP) }
        menu.addItem(ts)
        let warp = NSMenuItem(title: "WARP", action: #selector(switchWARP), keyEquivalent: "")
        warp.target = self
        warp.state = warpState() == "connected" ? .on : .off
        menu.addItem(warp)

        // Permission rows only while one is missing.
        var grants: [NSMenuItem] = []
        if !CGPreflightScreenCaptureAccess() {
            grants.append(warning("⚠ Grant Screen Recording…", #selector(grantScreenRecording)))
        }
        if !AXIsProcessTrusted() {
            grants.append(warning("⚠ Grant Accessibility…", #selector(grantAccessibility)))
        }
        if !grants.isEmpty {
            menu.addItem(.separator())
            for g in grants { menu.addItem(g) }
        }

        menu.addItem(.separator())
        for (t, sel) in [("Open panel", #selector(openPanel)), ("Pair phone…", #selector(showPairingQR)),
                         ("Setup…", #selector(openOnboarding))] {
            let mi = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            mi.target = self
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // "Title" plus grey secondary text, for menu rows.
    private func titled(_ title: String, secondary: String, dot: NSColor? = nil) -> NSAttributedString {
        let s = NSMutableAttributedString()
        if let dot = dot { s.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: dot])) }
        s.append(NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor]))
        s.append(NSAttributedString(string: "  \(secondary)",
                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        return s
    }

    private func warning(_ title: String, _ action: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemOrange])
        return mi
    }

    // ---------- health ----------

    private static let isoParser = ISO8601DateFormatter()

    private func healthItem() -> NSMenuItem {
        let h = Health.shared
        let snap = h.snapshot()
        let rows = snap["watches"] as? [[String: Any]] ?? []
        let s = snap["summary"] as? [String: Int] ?? [:]
        var title: String
        if h.isOff {
            title = "Health: no watches.json"
        } else {
            let bad = ["down", "failing", "error"].compactMap { k in (s[k] ?? 0) > 0 ? "\(s[k]!) \(k)" : nil }
            if rows.isEmpty {
                title = h.lastError != nil ? "Health: config error" : "Health: checking…"
            } else {
                title = bad.isEmpty ? "Health: all OK (\(rows.count))" : "Health: " + bad.joined(separator: ", ")
                if h.lastError != nil { title += " (config error)" }
            }
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if let e = h.lastError, !h.isOff { sub.addItem(disabled("Config error: \(e)")) }
        let colors: [String: NSColor] = ["ok": .systemGreen, "failing": .systemOrange,
                                         "down": .systemRed, "error": .systemGray]
        let rank = ["down": 0, "failing": 1, "error": 2, "ok": 3]
        // Stable sort: problems first, config order inside each group.
        let sorted = rows.enumerated().sorted {
            (rank[$0.element["status"] as? String ?? ""] ?? 9, $0.offset)
                < (rank[$1.element["status"] as? String ?? ""] ?? 9, $1.offset)
        }.map(\.element)
        let now = Date()
        var sawProblem = false
        var sawOK = false
        for w in sorted {
            let name = w["name"] as? String ?? "?"
            let status = w["status"] as? String ?? "?"
            let ok = status == "ok"
            let err = ok ? "" : (w["last_error"] as? String ?? "")
            let hint = w["hint"] as? String ?? ""
            let age = (w["since"] as? String).flatMap { Self.isoParser.date(from: $0) }
                .map { fmtDuration(now.timeIntervalSince($0)) } ?? ""
            if ok && sawProblem && !sawOK { sub.addItem(.separator()) }
            if ok { sawOK = true } else { sawProblem = true }

            var detail = ok ? age : [status, age].filter { !$0.isEmpty }.joined(separator: " ")
            if !err.isEmpty { detail += " · " + (err.count > 40 ? String(err.prefix(40)) + "…" : err) }
            let wi = NSMenuItem(title: name, action: #selector(copyWatch(_:)), keyEquivalent: "")
            wi.target = self
            wi.attributedTitle = titled(name, secondary: detail, dot: colors[status] ?? .systemGray)
            wi.representedObject = ["\(name): \(status)", err, hint].filter { !$0.isEmpty }.joined(separator: ". ")
            sub.addItem(wi)
            if !ok, w["fix"] is String {
                let fi = NSMenuItem(title: "Fix \(name)", action: #selector(fixWatch(_:)), keyEquivalent: "")
                fi.target = self
                fi.representedObject = name
                fi.indentationLevel = 1
                sub.addItem(fi)
            }
        }
        sub.addItem(.separator())
        for (t, sel) in [("Open health.json", #selector(openHealthJSON)), ("Edit watches.json", #selector(editWatches)),
                         ("Copy health summary", #selector(copyHealth))] {
            let mi = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            mi.target = self
            sub.addItem(mi)
        }
        item.submenu = sub
        return item
    }

    @objc private func copyWatch(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func fixWatch(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let fix = Health.shared.watches.first(where: { $0.name == name })?.fix else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Run the fix for \(name)?"
        alert.informativeText = fix
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch Health.shared.startFix(name: name) {
        case .busy: notice("A fix is already running.")
        case .started, .unknown, .noFix: break
        }
    }

    @objc private func openHealthJSON() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Health.shared.statePath))
    }

    @objc private func editWatches() {
        let path = Health.shared.configPath
        guard FileManager.default.fileExists(atPath: path) else {
            notice("No watches.json yet. Create \(path) (see docs/HEALTH.md).")
            return
        }
        // -t = the default text editor, not whatever app owns .json.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-t", path]
        try? proc.run()
    }

    @objc private func copyHealth() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Health.shared.summaryText(), forType: .string)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // ---------- network state ----------

    private func tailscaleState() -> (Bool, String) {
        guard let ts = Shell.tailscale else { return (false, "") }
        let (code, _) = Shell.run(ts, ["status"])
        let up = code == 0
        var ip = ""
        if up {
            let (_, out) = Shell.run(ts, ["ip", "-4"])
            ip = out.split(separator: "\n").first.map(String.init) ?? ""
        }
        return (up, ip)
    }

    private func warpState() -> String {
        guard let warp = Shell.warpCli else { return "not installed" }
        let (_, out) = Shell.run(warp, ["status"])
        if out.localizedCaseInsensitiveContains("Connected") { return "connected" }
        if out.localizedCaseInsensitiveContains("Disconnected") { return "disconnected" }
        return out.isEmpty ? "unknown" : out.split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    // ---------- actions ----------

    @objc private func switchTailscale() { confirmVPN(arg: "ts", label: "Tailscale") }
    @objc private func switchWARP() { confirmVPN(arg: "cf", label: "WARP") }

    private func confirmVPN(arg: String, label: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Switch to \(label)?"
        alert.informativeText = "This drops your current VPN session. Continue?"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let vpn = Shell.vpn else {
            self.notice("vpn tool not found at ~/.local/bin/vpn")
            return
        }
        DispatchQueue.global().async {
            _ = Shell.run(vpn, [arg], timeout: 30)
        }
    }

    @objc private func grantScreenRecording() {
        // Nudge the TCC prompt, then open the pane.
        CGRequestScreenCaptureAccess()
        openSettings("com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func grantAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    private func openSettings(_ tail: String) {
        if let url = URL(string: "x-apple.systempreferences:\(tail)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPanel() {
        // panelURL always carries the auth token now.
        if let url = URL(string: Config.shared.panelURL) { NSWorkspace.shared.open(url) }
    }

    @objc private func showPairingQR() {
        QRWindowController.shared.show()
    }

    @objc private func openOnboarding() {
        OnboardingWindowController.shared.show()
    }

    // Not private: onboarding's Pair phone step has a "Copy ntfy topic" button.
    @objc func copyTopic() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Config.shared.topic, forType: .string)
    }

    // Not private: onboarding's "Status server" Save restarts through here.
    @objc func restart() {
        let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let proc = Process()
        proc.executableURL = url
        try? proc.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func notice(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "Nodlock"
        alert.informativeText = text
        alert.runModal()
    }
}
