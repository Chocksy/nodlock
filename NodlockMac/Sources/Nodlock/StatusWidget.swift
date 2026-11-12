import AppKit
import SwiftUI

// Floating desktop status card, after deye-widget / llmactivity: borderless,
// translucent, at desktop level, draggable, position remembered, scalable.
// Small and calm when all is ok; a hero card per the worst problem otherwise.

final class OpsModel: ObservableObject {
    static let shared = OpsModel()
    @Published var snap = OpsSnapshot()
    @Published var scale: Double = {
        let v = UserDefaults.standard.double(forKey: "widgetScale")
        return v == 0 ? 1 : v
    }() {
        didSet { UserDefaults.standard.set(scale, forKey: "widgetScale") }
    }
    @Published var now = Date()

    func refresh() {
        let s = OpsStatus.shared.snapshot()
        if s != snap { snap = s }
        now = Date() // ages tick
    }
}

func ageText(_ started: String?, now: Date) -> String {
    parseISO(started).map { fmtDuration(now.timeIntervalSince($0)) } ?? ""
}

struct StatusCardView: View {
    @ObservedObject var model: OpsModel

    private var s: CGFloat { CGFloat(model.scale) }
    private func font(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .system(size: size * s, weight: w) }
    private func color(_ sev: String) -> Color { Color(nsColor: severityColor(sev)) }

    var body: some View {
        let items = model.snap.items
        let loud = items.filter { severityRank($0.severity) >= 3 }
        let quiet = items.filter { severityRank($0.severity) < 3 }
        VStack(alignment: .leading, spacing: 8 * s) {
            if let hero = loud.first {
                heroCard(hero)
                ForEach(loud.dropFirst(), id: \.id) { row($0, bold: true) }
            } else {
                HStack(spacing: 8 * s) {
                    let unknown = quiet.contains { $0.severity == "unreachable" }
                    Circle().fill(color(unknown ? "unreachable" : "ok")).frame(width: 9 * s, height: 9 * s)
                    Text(unknown ? "Status unknown" : "All good").font(font(15, .semibold))
                }
            }
            ForEach(quiet, id: \.id) { row($0, bold: false) }
            if !model.snap.apps.isEmpty { appDots }
        }
        .padding(.horizontal, 16 * s)
        .padding(.vertical, 13 * s)
        .frame(width: loud.isEmpty ? nil : 320 * s, alignment: .leading)
        .fixedSize()
    }

    private func heroCard(_ i: OpsItem) -> some View {
        let c = color(i.severity)
        return VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * s) {
                Text(i.severity == "911" ? "911" : "WARNING")
                    .font(font(10, .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 6 * s).padding(.vertical, 2 * s)
                    .background(c, in: Capsule())
                if !i.app.isEmpty { Text(i.app).font(font(11, .medium)).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Text(ageText(i.started_at, now: model.now)).font(font(11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(i.title).font(font(16, .bold)).fixedSize(horizontal: false, vertical: true)
            if !i.summary.isEmpty {
                Text(i.summary).font(font(12.5)).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !i.action.isEmpty {
                Text("→ " + i.action).font(font(12.5, .medium)).foregroundStyle(c)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if i.grafana != nil || i.claude != nil {
                HStack(spacing: 8 * s) {
                    if let g = i.grafana { linkButton("Open in Grafana", g, filled: true, tint: c) }
                    if let q = i.claude { linkButton("Ask Claude", q, filled: false, tint: c) }
                }
                .padding(.top, 2 * s)
            }
        }
        .padding(12 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.opacity(0.16), in: RoundedRectangle(cornerRadius: 14 * s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14 * s, style: .continuous).strokeBorder(c.opacity(0.5), lineWidth: 1))
    }

    private func linkButton(_ title: String, _ link: String, filled: Bool, tint: Color) -> some View {
        Button {
            if let u = URL(string: link) { NSWorkspace.shared.open(u) }
        } label: {
            Text(title).font(font(12, .semibold))
                .foregroundStyle(filled ? Color.white : Color.primary)
                .padding(.horizontal, 10 * s).padding(.vertical, 5 * s)
                .background(filled ? tint : Color.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ i: OpsItem, bold: Bool) -> some View {
        Button {
            if let l = i.link, let u = URL(string: l) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 7 * s) {
                Circle().fill(color(i.severity)).frame(width: 7 * s, height: 7 * s)
                Text(i.title).font(font(12, bold ? .semibold : .regular)).lineLimit(1)
                    .foregroundStyle(bold ? .primary : .secondary)
                Spacer(minLength: 6)
                Text(ageText(i.started_at, now: model.now)).font(font(11)).foregroundStyle(.tertiary).monospacedDigit()
            }
            .frame(maxWidth: 320 * s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var appDots: some View {
        HStack(spacing: 10 * s) {
            ForEach(model.snap.apps, id: \.name) { a in
                HStack(spacing: 4 * s) {
                    Circle().fill(color(a.status)).frame(width: 7 * s, height: 7 * s)
                    Text(a.name).font(font(10.5)).foregroundStyle(.secondary)
                }
                .help(a.detail)
            }
        }
    }
}

// Clicks on empty card space drag the window; SwiftUI buttons still get theirs.
// The app is an accessory, so the first click on the inactive window must count.
private final class DraggableHostingView<V: View>: NSHostingView<V> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class StatusWidgetWindow: NSWindow {
    static let shared = StatusWidgetWindow()
    private let cornerRadius: CGFloat = 22
    private let hosting = DraggableHostingView(rootView: StatusCardView(model: OpsModel.shared))

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showWidget") }
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary]

        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.maskImage = Self.roundedMask(radius: cornerRadius)
        visual.wantsLayer = true
        visual.layer?.cornerRadius = cornerRadius
        visual.layer?.cornerCurve = .continuous
        visual.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: visual.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
        ])
        contentView = visual

        setFrameAutosaveName("NodlockStatusWidget")
        if frame.origin == .zero, let sf = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: sf.maxX - 360, y: sf.maxY - 120))
        }
        refit()
    }

    // The card grows and shrinks with its content; keep the top-left corner fixed.
    func refit() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size != frame.size, size.width > 0 else { return }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
        invalidateShadow()
    }

    func sync() {
        if Self.enabled {
            refit()
            if !isVisible { orderFrontRegardless() }
        } else if isVisible {
            orderOut(nil)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
