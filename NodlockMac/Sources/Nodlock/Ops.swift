import AppKit
import UserNotifications

// Ops status: the Hetzner JSON feed merged with the local health watches into one
// ranked list. The menu, the desktop widget and GET /ops (the phone) all read
// OpsSnapshot, so they always agree.

// 911 > warning > unreachable (grey, the feed itself is down) > spike > ok.
let SEVERITY_RANK = ["911": 4, "warning": 3, "unreachable": 2, "spike": 1, "ok": 0]
func severityRank(_ s: String) -> Int { SEVERITY_RANK[s] ?? 0 }

// snake_case on purpose: this is also the /ops wire format the iOS app decodes.
struct OpsItem: Codable, Equatable {
    var id: String
    var severity: String
    var title: String
    var summary = ""
    var action = ""
    var app = ""
    var started_at: String?
    var grafana: String?
    var claude: String?

    var link: String? { grafana ?? claude }
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
    var items: [OpsItem] = []   // ranked, worst first; never "ok"
    var apps: [OpsAppRow] = []
    var servers: [String] = []
    var feed_error: String?
}

let FEED_DOWN_AFTER = 3

private let isoPlain = ISO8601DateFormatter()
private let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func parseISO(_ s: String?) -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    return isoPlain.date(from: s) ?? isoFrac.date(from: s)
}

func normSeverity(_ v: Any?) -> String {
    let s = ((v as? String) ?? (v as? NSNumber)?.stringValue ?? "").lowercased()
    if SEVERITY_RANK[s] != nil && s != "unreachable" { return s }
    return s.isEmpty ? "ok" : "warning" // unknown value: surface it rather than hide it
}

private func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
private func pct(_ v: Any?) -> String? { num(v).map { "\(Int($0.rounded()))%" } }

// "Hetzner  RAM 44% free (min 4% 24h) · disk 45% · swap 48%"
func serverLine(_ s: [String: Any]) -> String {
    var parts: [String] = []
    if let r = pct(s["ram_free_pct"]) {
        parts.append("RAM \(r) free" + (pct(s["ram_free_min_24h"]).map { " (min \($0) 24h)" } ?? ""))
    }
    if let d = pct(s["disk_pct"]) {
        parts.append("disk \(d)" + (num(s["disk_days_left"]).map { " (full in \(Int($0))d)" } ?? ""))
    }
    if let w = pct(s["swap_pct"]) { parts.append("swap \(w)") }
    if let c = pct(s["conn_pct"]) { parts.append("conn \(c)") }
    if let k = num(s["oom_kills_24h"]), k > 0 { parts.append("\(Int(k)) OOM kills 24h") }
    return "\(s["name"] as? String ?? "?")  " + parts.joined(separator: " · ")
}

func appDetail(_ services: [[String: Any]]) -> String {
    guard !services.isEmpty else { return "" }
    let down = services.filter { ($0["up"] as? Bool) == false }.compactMap { $0["name"] as? String }
    if down.isEmpty { return services.count == 1 ? "up" : "all \(services.count) up" }
    return "\(down.count) of \(services.count) down: " + down.joined(separator: ", ")
}

// Pure merge, so it is testable: last good feed (may be stale) + local watch rows.
func buildSnapshot(feed: [String: Any]?, feedError: String?, failures: Int,
                   watches: [[String: Any]]) -> OpsSnapshot {
    var snap = OpsSnapshot()
    var items: [OpsItem] = []
    if let f = feed {
        snap.generated_at = f["generated_at"] as? String
        snap.headline = f["headline"] as? String ?? ""
        for a in f["alerts"] as? [[String: Any]] ?? [] {
            let sev = normSeverity(a["severity"])
            guard sev != "ok" else { continue }
            let links = a["links"] as? [String: Any] ?? [:]
            items.append(OpsItem(
                id: (a["id"] as? String) ?? (a["title"] as? String) ?? UUID().uuidString,
                severity: sev, title: a["title"] as? String ?? "Alert",
                summary: a["summary"] as? String ?? "", action: a["action"] as? String ?? "",
                app: a["app"] as? String ?? "",
                started_at: parseISO(a["started_at"] as? String).map(iso),
                grafana: (links["grafana"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                claude: (links["claude"] as? String).flatMap { $0.isEmpty ? nil : $0 }))
        }
        let order = ["Tapselo", "EpicPxls", "EpicFinance", "Infra"] // unknown apps go last, feed order
        snap.apps = (f["apps"] as? [[String: Any]] ?? []).enumerated().map { i, a in
            (order.firstIndex(of: a["name"] as? String ?? "") ?? order.count + i,
             OpsAppRow(name: a["name"] as? String ?? "?", status: normSeverity(a["status"]),
                       detail: appDetail(a["services"] as? [[String: Any]] ?? [])))
        }.sorted { $0.0 < $1.0 }.map(\.1)
        snap.servers = (f["servers"] as? [[String: Any]] ?? []).map(serverLine)
        if let k = f["kiosks"] as? [String: Any], let on = k["online"] as? Int, let total = k["total"] as? Int {
            let off = k["offline"] as? [String] ?? []
            snap.servers.append("Kiosks  \(on)/\(total) online" + (off.isEmpty ? "" : " · off: " + off.joined(separator: ", ")))
        }
        let o = normSeverity(f["overall"])
        if severityRank(o) > severityRank(snap.overall) { snap.overall = o }
    }
    // Local Mac watches: down = warning, failing (one miss) = spike.
    for w in watches {
        let st = w["status"] as? String ?? ""
        guard st == "down" || st == "failing", let name = w["name"] as? String else { continue }
        items.append(OpsItem(id: "mac:\(name)", severity: st == "down" ? "warning" : "spike",
                             title: "Mac: \(name) is \(st)", summary: w["last_error"] as? String ?? "",
                             action: w["hint"] as? String ?? "", app: "Mac", started_at: w["since"] as? String))
    }
    if failures >= FEED_DOWN_AFTER {
        snap.feed_error = feedError ?? "unreachable"
        items.append(OpsItem(id: "feed", severity: "unreachable", title: "Status feed unreachable",
                             summary: snap.feed_error!, action: feed == nil ? "" : "Apps and servers below are stale."))
    }
    // Stable sort: worst first, feed order inside a severity.
    snap.items = items.enumerated().sorted {
        (-severityRank($0.element.severity), $0.offset) < (-severityRank($1.element.severity), $1.offset)
    }.map(\.element)
    for i in snap.items where i.severity != "unreachable" && severityRank(i.severity) > severityRank(snap.overall) {
        snap.overall = i.severity
    }
    return snap
}

// Keys to notify on: warning/911 items not seen before. Escalation (warning -> 911)
// is a new key, so it notifies again; a resolved alert that comes back does too.
func notifyKeys(_ items: [OpsItem]) -> [String: OpsItem] {
    var out: [String: OpsItem] = [:]
    for i in items where i.severity == "warning" || i.severity == "911" { out["\(i.id)|\(i.severity)"] = i }
    return out
}

final class OpsStatus: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OpsStatus(envPath: ("~/.config/op-guard/ops-status.env" as NSString).expandingTildeInPath)

    let url: String
    let token: String
    private let lock = NSLock()
    private var feed: [String: Any]?
    private var failures = 0
    private var lastError: String?
    private let seenKey = "opsNotified"

    init(envPath: String) {
        var v = Config.readEnvFile(envPath)
        for (k, val) in ProcessInfo.processInfo.environment where k.hasPrefix("OPS_STATUS_") { v[k] = val }
        url = v["OPS_STATUS_URL"] ?? ""
        token = v["OPS_STATUS_TOKEN"] ?? ""
    }

    var isConfigured: Bool { !url.isEmpty }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { ok, err in
            if !ok { FileHandle.standardError.write(Data("nodlock: notifications off: \(err.map { "\($0)" } ?? "denied")\n".utf8)) }
        }
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 3) // let Health finish its first cycle
            while true {
                if self.isConfigured { self.poll() }
                self.notify(self.snapshot().items)
                Thread.sleep(forTimeInterval: 60)
            }
        }
    }

    func poll() {
        let (obj, err) = fetchFeed()
        lock.lock(); defer { lock.unlock() }
        if let obj = obj {
            feed = obj; failures = 0; lastError = nil
        } else {
            failures += 1; lastError = err
            FileHandle.standardError.write(Data("nodlock: ops feed failed (\(failures)): \(err ?? "?")\n".utf8))
        }
    }

    private func fetchFeed() -> ([String: Any]?, String?) {
        guard let u = URL(string: url), u.scheme != nil else { return (nil, "bad OPS_STATUS_URL") }
        let data: Data?
        if u.isFileURL { // fixture: OPS_STATUS_URL=file:///path/feed.json
            data = try? Data(contentsOf: u)
            if data == nil { return (nil, "cannot read \(u.path)") }
        } else {
            var req = URLRequest(url: u)
            req.timeoutInterval = 15
            if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (code, d, err) = fetch(req, deadline: 16)
            if let err = err { return (nil, short(err)) }
            guard code == 200 else { return (nil, "HTTP \(code)") }
            data = d
        }
        guard let obj = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] else {
            return (nil, "bad JSON")
        }
        return (obj, nil)
    }

    func snapshot() -> OpsSnapshot {
        let watches = Health.shared.snapshot()["watches"] as? [[String: Any]] ?? []
        lock.lock(); defer { lock.unlock() }
        return buildSnapshot(feed: feed, feedError: lastError, failures: failures, watches: watches)
    }

    func json() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return (try? enc.encode(snapshot())) ?? Data("{}".utf8)
    }

    // ---------- macOS notifications ----------

    private func notify(_ items: [OpsItem]) {
        let current = notifyKeys(items)
        let seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? [])
        // Keep only keys still active, so a resolved alert that comes back notifies again.
        UserDefaults.standard.set(Array(current.keys), forKey: seenKey)
        for (key, item) in current where !seen.contains(key) {
            let c = UNMutableNotificationContent()
            c.title = (item.severity == "911" ? "911: " : "") + item.title
            c.body = [item.summary, item.action].filter { !$0.isEmpty }.joined(separator: "\n")
            c.sound = .default
            if let link = item.link { c.userInfo = ["url": link] }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: c, trigger: nil))
            FileHandle.standardError.write(Data("nodlock: ops notify \(key)\n".utf8))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let u = URL(string: s) {
            DispatchQueue.main.async { NSWorkspace.shared.open(u) }
        }
        done()
    }
}

func severityColor(_ s: String) -> NSColor {
    switch s {
    case "911": return .systemRed
    case "warning": return .systemOrange
    case "spike": return .systemYellow
    case "ok": return .systemGreen
    default: return .systemGray
    }
}
