import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Small always-on-top window that shows a QR code encoding Config.shared.pairingPayload.
// The iOS app scans it to pair (host + token in one shot). A single instance is
// reused across opens; reopening refreshes the QR and the URL label.
final class QRWindowController {
    static let shared = QRWindowController()

    private var window: NSWindow?
    private var qrView: NSImageView?
    private var urlLabel: NSTextField?

    private init() {}

    // Create the window on first use, or refresh + reveal an existing one.
    func show() {
        let url = Config.shared.pairingPayload

        if let window = window {
            refresh(url: url)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))

        // QR image, crisp nearest-neighbor scale to ~260x260 pt.
        let imageView = NSImageView(frame: NSRect(x: 30, y: 110, width: 260, height: 260))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = QRCode.image(from: url, side: 260)
        content.addSubview(imageView)
        qrView = imageView

        // Caption above the QR.
        let caption = NSTextField(labelWithString: "Scan in the Nodlock iOS app")
        caption.frame = NSRect(x: 0, y: 372, width: 320, height: 18)
        caption.alignment = .center
        caption.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        caption.textColor = .secondaryLabelColor
        content.addSubview(caption)

        // Monospaced, selectable URL for manual-paste fallback.
        let url_ = NSTextField(wrappingLabelWithString: url)
        url_.frame = NSRect(x: 20, y: 48, width: 280, height: 52)
        url_.alignment = .center
        url_.isSelectable = true
        url_.isEditable = false
        url_.drawsBackground = false
        url_.isBezeled = false
        url_.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        url_.textColor = .labelColor
        url_.lineBreakMode = .byCharWrapping
        url_.maximumNumberOfLines = 3
        content.addSubview(url_)
        urlLabel = url_

        // Copy URL button.
        let copy = NSButton(title: "Copy URL", target: self, action: #selector(copyURL))
        copy.frame = NSRect(x: 110, y: 12, width: 100, height: 28)
        copy.bezelStyle = .rounded
        content.addSubview(copy)

        let win = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "Pair Nodlock"
        win.contentView = content
        win.isReleasedWhenClosed = false // reuse across opens
        win.level = .floating           // always-on-top
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func refresh(url: String) {
        qrView?.image = QRCode.image(from: url, side: 260)
        urlLabel?.stringValue = url
    }

    @objc private func copyURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(Config.shared.pairingPayload, forType: .string)
    }

    // Generate a QR code for `string` and render it to a crisp NSImage of the
    // given point size using nearest-neighbor scaling (no blur on the modules).
}
