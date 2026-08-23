import UIKit

// A fake Mac, entirely on-device.
//
// App Review has no Mac running the companion menu-bar app, so "Try a demo" on
// the pairing screen installs a pairing pointed at `demo://local` and every
// call the unlock screen makes lands here instead of on the network. The UI is
// the real UI: same poll loop, same screenshot view, same type/key/click calls.
//
// Script: idle -> after ~5s a "1Password" prompt appears -> typing anything
// clears it after ~1s and records a login -> Esc dismisses it. Then it arms
// again, so the reviewer can run the flow as many times as they like.
final class DemoClient: PanelClient {
    static let shared = DemoClient()

    private let promptDelay: TimeInterval = 5   // idle -> fake prompt
    private let typeDelay: TimeInterval = 1     // fake round trip to the Mac

    private let lock = NSLock()
    private var startedAt = Date()
    private var idleSince = Date()
    private var dialogOwner: String?
    private var loginList: [LoginRequest] = [DemoClient.seedLogin()]
    private var cachedShot: Data?

    private init() {}

    // Wiped on unpair so a second demo starts from a clean script.
    func reset() {
        lock.withLock {
            startedAt = Date()
            idleSince = Date()
            dialogOwner = nil
            loginList = [DemoClient.seedLogin()]
        }
    }

    private static func seedLogin() -> LoginRequest {
        LoginRequest(url: "https://github.com/login/device", ts: Int(Date().timeIntervalSince1970))
    }

    // MARK: - PanelClient

    func status() async throws -> SentinelStatus {
        let (owner, uptime, logins) = lock.withLock { () -> (String?, TimeInterval, [LoginRequest]) in
            let now = Date()
            if dialogOwner == nil, now.timeIntervalSince(idleSince) >= promptDelay {
                dialogOwner = "1Password"
            }
            return (dialogOwner, now.timeIntervalSince(startedAt), loginList)
        }

        return SentinelStatus(
            ok: true,
            uptime_s: uptime,
            pushes: 0,
            topic_set: true,
            panel_url: Pairing.demoBase,
            dialog: owner,
            logins: logins
        )
    }

    func screenshot() async throws -> Data? {
        if let cached = lock.withLock({ cachedShot }) { return cached }

        let data = await MainActor.run { DemoClient.renderDialogShot() }
        lock.withLock { cachedShot = data }
        return data
    }

    func type(text: String, enter: Bool) async throws {
        guard !text.isEmpty else { return }
        try? await Task.sleep(nanoseconds: UInt64(typeDelay * 1_000_000_000))
        lock.withLock {
            dialogOwner = nil
            idleSince = Date()
            loginList.insert(
                LoginRequest(url: "https://accounts.google.com/signin", ts: Int(Date().timeIntervalSince1970)),
                at: 0
            )
        }
    }

    func key(_ k: String) async throws {
        guard k == "esc" else { return }
        lock.withLock {
            dialogOwner = nil
            idleSince = Date()
        }
    }

    func click(fx: Double, fy: Double) async throws {}

    func registerPush(deviceTokenHex: String) async throws {}

    func unregisterPush(deviceTokenHex: String) async throws {}

    func clearLogins() async throws {
        lock.withLock { loginList = [] }
    }

    // MARK: - The mock screenshot

    // Drawn once at runtime and cached, so nothing has to ship in the bundle.
    // 800x754 matches the aspect of a real captured macOS dialog.
    @MainActor
    private static func renderDialogShot() -> Data {
        let size = CGSize(width: 800, height: 754)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext

            // Desktop backdrop behind the dialog.
            if let bg = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.04, green: 0.05, blue: 0.09, alpha: 1).cgColor,
                         UIColor(red: 0.10, green: 0.11, blue: 0.19, alpha: 1).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                cg.drawLinearGradient(bg, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }

            // The dialog card.
            let card = CGRect(x: 140, y: 187, width: 520, height: 380)
            let cardPath = UIBezierPath(roundedRect: card, cornerRadius: 22)
            cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 40,
                         color: UIColor(white: 0, alpha: 0.55).cgColor)
            UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 1).setFill()
            cardPath.fill()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor(white: 1, alpha: 0.14).setStroke()
            cardPath.lineWidth = 1.5
            cardPath.stroke()

            // Lock glyph.
            let cfg = UIImage.SymbolConfiguration(pointSize: 46, weight: .semibold)
            if let glyph = UIImage(systemName: "lock.fill", withConfiguration: cfg)?
                .withTintColor(UIColor(red: 0.30, green: 0.55, blue: 1, alpha: 1),
                               renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: card.midX - glyph.size.width / 2, y: card.minY + 36))
            }

            draw("1Password is trying to unlock",
                 in: CGRect(x: card.minX + 24, y: card.minY + 118, width: card.width - 48, height: 40),
                 font: .systemFont(ofSize: 27, weight: .semibold), color: .white)

            draw("Enter your password to allow access.",
                 in: CGRect(x: card.minX + 24, y: card.minY + 162, width: card.width - 48, height: 26),
                 font: .systemFont(ofSize: 16, weight: .regular),
                 color: UIColor(white: 1, alpha: 0.55))

            // Password field outline.
            let field = CGRect(x: card.minX + 40, y: card.minY + 210, width: card.width - 80, height: 54)
            let fieldPath = UIBezierPath(roundedRect: field, cornerRadius: 12)
            UIColor(white: 0, alpha: 0.35).setFill()
            fieldPath.fill()
            UIColor(red: 0.30, green: 0.55, blue: 1, alpha: 0.9).setStroke()
            fieldPath.lineWidth = 2
            fieldPath.stroke()
            draw("\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}",
                 in: CGRect(x: field.minX + 18, y: field.midY - 15, width: field.width - 36, height: 30),
                 font: .systemFont(ofSize: 22, weight: .semibold),
                 color: UIColor(white: 1, alpha: 0.8), align: .left)

            // Cancel / Unlock buttons.
            let cancel = CGRect(x: card.minX + 40, y: card.minY + 296, width: 200, height: 50)
            let unlock = CGRect(x: card.minX + 280, y: card.minY + 296, width: 200, height: 50)

            let cancelPath = UIBezierPath(roundedRect: cancel, cornerRadius: 12)
            UIColor(white: 1, alpha: 0.08).setFill()
            cancelPath.fill()
            UIColor(white: 1, alpha: 0.16).setStroke()
            cancelPath.lineWidth = 1
            cancelPath.stroke()
            draw("Cancel", in: CGRect(x: cancel.minX, y: cancel.midY - 12, width: cancel.width, height: 24),
                 font: .systemFont(ofSize: 17, weight: .medium), color: UIColor(white: 1, alpha: 0.75))

            UIColor(red: 0.30, green: 0.55, blue: 1, alpha: 1).setFill()
            UIBezierPath(roundedRect: unlock, cornerRadius: 12).fill()
            draw("Unlock", in: CGRect(x: unlock.minX, y: unlock.midY - 12, width: unlock.width, height: 24),
                 font: .systemFont(ofSize: 17, weight: .semibold), color: .white)
        }

        return image.pngData() ?? Data()
    }

    @MainActor
    private static func draw(_ text: String, in rect: CGRect, font: UIFont,
                             color: UIColor, align: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = .byClipping
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }
}
