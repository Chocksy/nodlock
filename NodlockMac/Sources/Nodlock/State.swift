import Foundation
import CoreGraphics

struct Dialog {
    let id: Int
    let owner: String
    let title: String
    let x: Double
    let y: Double
    let w: Double
    let h: Double
}

// Shared, thread-safe state (watcher thread + HTTP handler threads).
final class AppState {
    static let shared = AppState()

    private let lock = NSLock()
    private var _dialog: Dialog?
    private var _pushes = 0
    private var alerted = Set<Int>()
    private var _logins: [(url: String, ts: Int)] = []
    let started = Int(Date().timeIntervalSince1970)

    var dialog: Dialog? {
        lock.lock(); defer { lock.unlock() }
        return _dialog
    }
    func setDialog(_ d: Dialog?) {
        lock.lock(); defer { lock.unlock() }
        _dialog = d
    }

    var pushes: Int {
        lock.lock(); defer { lock.unlock() }
        return _pushes
    }
    func incrementPushes() {
        lock.lock(); defer { lock.unlock() }
        _pushes += 1
    }

    func isAlerted(_ id: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return alerted.contains(id)
    }
    func markAlerted(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        alerted.insert(id)
    }

    // Ring buffer of the last 10 login requests (newest-first).
    func addLogin(_ url: String) {
        lock.lock(); defer { lock.unlock() }
        _logins.insert((url: url, ts: Int(Date().timeIntervalSince1970)), at: 0)
        if _logins.count > 10 { _logins.removeLast(_logins.count - 10) }
    }
    func loginsList() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return _logins.map { ["url": $0.url, "ts": $0.ts] }
    }
    func clearLogins() {
        lock.lock(); defer { lock.unlock() }
        _logins.removeAll()
    }

    var uptime: Int { Int(Date().timeIntervalSince1970) - started }
}

// Owners of the security-prompt windows we watch for.
let WATCH: Set<String> = [
    "1Password", "SecurityAgent", "CoreServicesUIAgent",
    "UserNotificationCenter", "LocalAuthenticationRemoteService"
]

// CGWindowListCopyWindowInfo, on-screen + exclude-desktop. First match with
// owner in WATCH and bounds >= 120x60.
func findDialog() -> Dialog? {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    for w in list {
        guard let owner = w[kCGWindowOwnerName as String] as? String, WATCH.contains(owner) else {
            continue
        }
        guard let boundsDict = w[kCGWindowBounds as String] else { continue }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard CGRectMakeWithDictionaryRepresentation((boundsDict as! CFDictionary), &rect) else {
            continue
        }
        if rect.width < 120 || rect.height < 60 { continue } // menu bar item / droppings
        let title = (w[kCGWindowName as String] as? String) ?? ""
        // 1Password owns BOTH the vault (shows secrets: credit cards, logins) AND
        // auth dialogs (unlock, "Access Requested"). Auth dialogs can be large, so
        // size alone can't tell them apart — key on the title. The vault window's
        // title carries item/vault context ("Login — Personal — 1Password",
        // "All Items"); auth dialogs are "1Password", "1Password Access Requested",
        // or empty. Exclude the vault by those title markers; allow auth of any size.
        if owner == "1Password" {
            let looksLikeVault = title.contains("—") || title.contains("–")
                || title.contains(" - ")
                || title.localizedCaseInsensitiveContains("all items")
            if looksLikeVault { continue }
        }
        let id = (w[kCGWindowNumber as String] as? Int) ?? 0
        return Dialog(id: id, owner: owner, title: title,
                      x: Double(rect.origin.x), y: Double(rect.origin.y),
                      w: Double(rect.width), h: Double(rect.height))
    }
    return nil
}
