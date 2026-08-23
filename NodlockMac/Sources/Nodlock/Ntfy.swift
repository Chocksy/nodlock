import Foundation

// PUT the PNG to ${OPG_NTFY}/${OPG_TOPIC} with Title/Priority/Tags/X-Filename,
// plus Actions when a panel URL is set. Pushed once per new window id (tracked
// by the watcher). Skips silently when no topic is configured.
func notify(dialog: Dialog, png: Data) {
    let cfg = Config.shared
    guard !cfg.topic.isEmpty else { return }
    guard let url = URL(string: "\(cfg.ntfy)/\(cfg.topic)") else { return }

    let host = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac"

    var req = URLRequest(url: url)
    req.httpMethod = "PUT"
    if !cfg.ntfyToken.isEmpty {
        req.setValue("Bearer \(cfg.ntfyToken)", forHTTPHeaderField: "Authorization")
    }
    req.setValue("\(dialog.owner) prompt on \(host)", forHTTPHeaderField: "Title")
    req.setValue("high", forHTTPHeaderField: "Priority")
    req.setValue("rotating_light", forHTTPHeaderField: "Tags")
    if !cfg.panelURL.isEmpty {
        req.setValue("view, Open panel, \(cfg.panelURL), clear=true", forHTTPHeaderField: "Actions")
    }
    if cfg.ntfyAttach {
        // Opt-in: attach the screenshot PNG (legacy behavior).
        req.setValue("dialog.png", forHTTPHeaderField: "X-Filename")
        req.httpBody = png
    } else {
        // Default: text-only push, no screenshot sent to the public ntfy server.
        // The screenshot stays viewable via the authed panel (GET /shot.png).
        req.httpBody = Data("\(dialog.owner) is asking to unlock — tap to approve".utf8)
    }
    req.timeoutInterval = 10

    let sem = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: req) { _, _, error in
        if let error = error {
            FileHandle.standardError.write(Data("nodlock: ntfy push failed: \(error)\n".utf8))
        }
        sem.signal()
    }
    task.resume()
    sem.wait()
}
