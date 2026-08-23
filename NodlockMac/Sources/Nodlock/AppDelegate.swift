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
            button.image = NSImage(systemSymbolName: "lock.shield", accessibilityDescription: "Nodlock")
            button.image?.isTemplate = true
            button.title = ""
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Start subsystems.
        startWatcher()
        server = HTTPServer(host: cfg.bind, port: cfg.port)
        do {
            try server.start()
            FileHandle.standardError.write(Data(
                "nodlock: panel on http://\(cfg.bind):\(cfg.port) (expose: tailscale serve --bg \(cfg.port))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("nodlock: failed to bind \(cfg.bind):\(cfg.port): \(error)\n".utf8))
        }

        // Reflect active-prompt state in the menu bar icon.
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
        let active = AppState.shared.dialog != nil
        let name = active ? "exclamationmark.shield.fill" : "lock.shield"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Nodlock")
        button.image?.isTemplate = !active
        button.contentTintColor = active ? .systemRed : nil
    }

    // Rebuild the menu on each open so status/VPN/permissions are live.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = AppState.shared
        let cfg = Config.shared
        let d = state.dialog

        // Status line.
        let statusTitle = d != nil ? "PROMPT ACTIVE: \(d!.owner)" : "Watching for prompts"
        let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        if d != nil {
            statusItem.attributedTitle = NSAttributedString(
                string: statusTitle,
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        }
        statusItem.isEnabled = false
        menu.addItem(statusItem)

        let mins = state.uptime / 60
        menu.addItem(disabled("Uptime: \(mins)m (\(state.uptime)s)"))
        menu.addItem(disabled("Pushes: \(state.pushes)"))

        menu.addItem(.separator())

        // Tailscale / WARP state.
        let (tsUp, tsIP) = tailscaleState()
        let tsLine = tsUp ? "Tailscale: up\(tsIP.isEmpty ? "" : " (\(tsIP))")" : "Tailscale: down"
        menu.addItem(disabled(tsLine))
        menu.addItem(disabled("WARP: \(warpState())"))

        let toTS = NSMenuItem(title: "Switch to Tailscale", action: #selector(switchTailscale), keyEquivalent: "")
        toTS.target = self
        menu.addItem(toTS)
        let toWARP = NSMenuItem(title: "Switch to WARP", action: #selector(switchWARP), keyEquivalent: "")
        toWARP.target = self
        menu.addItem(toWARP)

        menu.addItem(.separator())

        // Permission grants with live check state.
        let screenOK = CGPreflightScreenCaptureAccess()
        let grantScreen = NSMenuItem(title: "Grant Screen Recording…", action: #selector(grantScreenRecording), keyEquivalent: "")
        grantScreen.target = self
        grantScreen.state = screenOK ? .on : .off
        menu.addItem(grantScreen)

        let axOK = AXIsProcessTrusted()
        let grantAX = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")
        grantAX.target = self
        grantAX.state = axOK ? .on : .off
        menu.addItem(grantAX)

        menu.addItem(.separator())

        let openPanel = NSMenuItem(title: "Open panel", action: #selector(openPanel), keyEquivalent: "")
        openPanel.target = self
        menu.addItem(openPanel)

        let showQR = NSMenuItem(title: "Show Pairing QR…", action: #selector(showPairingQR), keyEquivalent: "")
        showQR.target = self
        menu.addItem(showQR)

        let setup = NSMenuItem(title: "Setup…", action: #selector(openOnboarding), keyEquivalent: "")
        setup.target = self
        menu.addItem(setup)

        let copyTopic = NSMenuItem(title: "Copy ntfy topic", action: #selector(copyTopic), keyEquivalent: "")
        copyTopic.target = self
        copyTopic.isEnabled = !cfg.topic.isEmpty
        menu.addItem(copyTopic)

        let restart = NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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

    @objc private func copyTopic() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Config.shared.topic, forType: .string)
    }

    @objc private func restart() {
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
