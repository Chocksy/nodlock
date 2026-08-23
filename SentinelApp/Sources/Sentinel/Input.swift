import Foundation
import CoreGraphics

let KEYCODES: [String: CGKeyCode] = ["return": 36, "esc": 53, "tab": 48]

// Clicks still use CGEvent (works reliably for the tap-to-click feature).
func clickAt(x: Double, y: Double) {
    let point = CGPoint(x: x, y: y)
    let src = CGEventSource(stateID: .hidSystemState)
    for type in [CGEventType.leftMouseDown, CGEventType.leftMouseUp] {
        let ev = CGEvent(mouseEventSource: src, mouseType: type,
                         mouseCursorPosition: point, mouseButton: .left)
        ev?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// Typing + key presses go through System Events (osascript). This is the path
// the original Python version used and that unlocked 1Password reliably; the
// raw CGEvent keyboardSetUnicodeString path typed text but its Return key did
// not submit secure dialogs.
private func runOsascript(_ script: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

// AppleScript string literal escaping: backslash and double-quote.
private func escapeForAppleScript(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
}

func typeText(_ s: String) {
    guard !s.isEmpty else { return }
    runOsascript("tell application \"System Events\" to keystroke \"\(escapeForAppleScript(s))\"")
}

func press(_ name: String) {
    guard let code = KEYCODES[name] else { return }
    runOsascript("tell application \"System Events\" to key code \(code)")
}
