import SwiftUI

// Shape of GET /ops on the Mac (OpsSnapshot in NodlockMac/Sources/Nodlock/Ops.swift).
// The Mac holds the feed token and does the ranking; the phone only renders.
struct OpsItem: Codable, Identifiable, Equatable {
    var id: String
    var severity: String     // 911 | warning | unreachable | spike
    var title: String
    var summary = ""
    var action = ""
    var app = ""
    var started_at: String?
    var grafana: String?
    var claude: String?
}

struct OpsAppRow: Codable, Equatable {
    var name: String
    var status: String
    var detail: String
}

struct OpsSnapshot: Codable, Equatable {
    var generated_at: String?
    var overall = "ok"
    var headline = ""
    var items: [OpsItem] = []
    var apps: [OpsAppRow] = []
    var servers: [String] = []
    var feed_error: String?
}

func severityColor(_ s: String) -> Color {
    switch s {
    case "911": return Theme.danger
    case "warning": return Theme.warn
    case "spike": return Color(hex: 0xFFE066)
    case "ok": return Theme.ok
    default: return Theme.dim
    }
}

struct StatusView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var snap: OpsSnapshot?
    @State private var error: String?
    @State private var now = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    LogoTile()
                    Text("Status").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.txt)
                    Spacer()
                    StatusChip(label: chipLabel, tone: chipTone)
                }
                .padding(.top, 6)

                if let snap {
                    problems(snap)
                    if !snap.apps.isEmpty { apps(snap) }
                    if !snap.servers.isEmpty { servers(snap) }
                } else {
                    GlassCard {
                        Text(error ?? "Loading…")
                            .font(.system(size: 14)).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var chipLabel: String {
        guard let snap else { return error == nil ? "loading" : "offline" }
        switch snap.overall {
        case "911": return "911"
        case "warning": return "needs a look"
        default: return snap.feed_error != nil ? "feed unreachable" : "all good"
        }
    }

    private var chipTone: ChipTone {
        switch snap?.overall {
        case "911": return .danger
        case "warning": return .warn
        case "ok": return snap?.feed_error != nil ? .dim : .ok
        default: return .dim
        }
    }

    private func load() async {
        guard let client = model.client else { return }
        do {
            snap = try await client.ops()
            error = nil
        } catch {
            // Older Macs answer /ops with the panel page, which does not decode.
            self.error = error is DecodingError ? "This Mac does not serve status yet. Update Nodlock on the Mac."
                                                : "Can't reach your Mac right now."
        }
        now = Date()
    }

    // MARK: - Sections

    @ViewBuilder private func problems(_ s: OpsSnapshot) -> some View {
        if s.items.isEmpty {
            GlassCard {
                HStack(spacing: 10) {
                    Circle().fill(Theme.ok).frame(width: 10, height: 10).shadow(color: Theme.ok, radius: 5)
                    Text(s.headline.isEmpty ? "All good" : s.headline)
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.txt)
                    Spacer()
                }
            }
        } else {
            ForEach(s.items) { i in
                if i.severity == "911" || i.severity == "warning" { hero(i) } else { quietRow(i) }
            }
        }
    }

    private func hero(_ i: OpsItem) -> some View {
        let c = severityColor(i.severity)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(i.severity == "911" ? "911" : "WARNING")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(.black)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(c, in: Capsule())
                if !i.app.isEmpty { Text(i.app).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.dim) }
                Spacer()
                Text(age(i.started_at)).font(.system(size: 13)).foregroundStyle(Theme.dim).monospacedDigit()
            }
            Text(i.title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.txt)
            if !i.summary.isEmpty { Text(i.summary).font(.system(size: 15)).foregroundStyle(Theme.txt.opacity(0.85)) }
            if !i.action.isEmpty { Text("→ " + i.action).font(.system(size: 15, weight: .medium)).foregroundStyle(c) }
            if i.grafana != nil || i.claude != nil {
                HStack(spacing: 8) {
                    if let g = i.grafana { linkButton("Open in Grafana", g) }
                    if let q = i.claude { linkButton("Ask Claude", q) }
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(c.opacity(0.45), lineWidth: 1))
    }

    private func linkButton(_ title: String, _ link: String) -> some View {
        Button(title) { if let u = URL(string: link) { UIApplication.shared.open(u) } }
            .buttonStyle(GhostButtonStyle())
    }

    private func quietRow(_ i: OpsItem) -> some View {
        HStack(spacing: 10) {
            Circle().fill(severityColor(i.severity)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(i.title).font(.system(size: 15)).foregroundStyle(Theme.txt)
                if !i.summary.isEmpty { Text(i.summary).font(.system(size: 12)).foregroundStyle(Theme.dim) }
            }
            Spacer()
            Text(age(i.started_at)).font(.system(size: 12)).foregroundStyle(Theme.dim).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func apps(_ s: OpsSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Apps").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.txt)
                ForEach(s.apps, id: \.name) { a in
                    HStack(spacing: 10) {
                        Circle().fill(severityColor(a.status)).frame(width: 8, height: 8)
                        Text(a.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.txt)
                        Spacer()
                        Text(a.detail).font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                }
            }
        }
    }

    private func servers(_ s: OpsSnapshot) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Servers").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.txt)
                ForEach(s.servers, id: \.self) { line in
                    let parts = line.components(separatedBy: "  ")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(parts[0]).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.txt)
                        Text(parts.dropFirst().joined(separator: "  ")).font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func age(_ started: String?) -> String {
        guard let started, let d = ISO8601DateFormatter().date(from: started) else { return "" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s / 60 % 60)m" }
        return "\(s / 86400)d"
    }
}
