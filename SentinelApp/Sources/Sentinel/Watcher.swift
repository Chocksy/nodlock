import Foundation

// Poll every 3s. On a new watched window: screenshot it, push once, count it.
func startWatcher() {
    Thread.detachNewThread {
        while true {
            let d = findDialog()
            AppState.shared.setDialog(d)
            if let d = d, !AppState.shared.isAlerted(d.id) {
                if let png = capturePNG(windowID: d.id) {
                    AppState.shared.markAlerted(d.id)
                    AppState.shared.incrementPushes()
                    FileHandle.standardError.write(
                        Data("sentinel: dialog \(d.owner) (\(d.id)) -> pushed\n".utf8))
                    // Prefer APNs when configured; ntfy is only a fallback when
                    // APNs isn't set up (title + owner only, no secrets).
                    if Config.shared.apnsEnabled {
                        APNs.shared.sendToAll(title: "\(d.owner) wants to unlock", owner: d.owner)
                    } else {
                        notify(dialog: d, png: png)
                    }
                }
            }
            Thread.sleep(forTimeInterval: 3)
        }
    }
}
