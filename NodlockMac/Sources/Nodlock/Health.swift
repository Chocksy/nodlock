import Foundation
import Network

// Health watches: checks from ~/.config/op-guard/watches.json every `interval`
// seconds, pushes on down / recovery, writes ~/.local/state/nodlock/health.json
// for the menu, the panel, `nodlockctl health` and coding agents.
// Docs: docs/HEALTH.md.

struct Watch: Equatable {
    let name: String
    let type: String
    let target: String
    let expect: [Int]?
    let timeout: Double
    let outside: Bool
    let fix: String?
    let hint: String?
}

extension Watch {
    // Same check = same type, target and expect (a new hint or fix keeps the history).
    func sameCheck(_ o: Watch) -> Bool { type == o.type && target == o.target && expect == o.expect }
}

struct WatchConfig: Equatable {
    let interval: Int
    let watches: [Watch]
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
}

// Throws on bad JSON, a watch without name/type/target, or a duplicate name.
// An unknown `type` parses fine; that watch reports `error` when checked.
func parseWatches(_ data: Data) throws -> WatchConfig {
    let obj: Any
    do {
        obj = try JSONSerialization.jsonObject(with: data)
    } catch {
        let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
        throw ConfigError(description: "invalid JSON: \(detail ?? error.localizedDescription)")
    }
    guard let root = obj as? [String: Any], let list = root["watches"] as? [[String: Any]] else {
        throw ConfigError(description: "missing \"watches\" array")
    }
    var seen = Set<String>()
    var out: [Watch] = []
    for (i, w) in list.enumerated() {
        let target = (w["target"] as? String) ?? (w["target"] as? NSNumber)?.stringValue
        guard let name = w["name"] as? String, !name.isEmpty,
              let type = w["type"] as? String, let target = target, !target.isEmpty else {
            throw ConfigError(description: "watch #\(i + 1): name, type and target are required")
        }
        guard seen.insert(name).inserted else {
            throw ConfigError(description: "duplicate watch name \"\(name)\"")
        }
        out.append(Watch(
            name: name, type: type, target: target,
            expect: (w["expect"] as? [Int]).flatMap { $0.isEmpty ? nil : $0 }, // [] = default, as on the server
            timeout: max(1, (w["timeout"] as? Double) ?? (type == "command" ? 10 : 5)),
            outside: (w["outside"] as? Bool) ?? false,
            fix: (w["fix"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            hint: w["hint"] as? String))
    }
    return WatchConfig(interval: max(15, (root["interval"] as? Int) ?? 60), watches: out)
}

// MARK: - State transitions (pure)

enum CheckResult: Equatable {
    case ok
    case fail(String)
    case error(String) // bad config for this watch
}

struct WatchState {
    var status = "ok"
    var since: Date
    var lastOK: Date?
    var lastError: String?
    var failures = 0
    var failSince: Date?  // first failure of the current outage
    var recoveriesToday = 0
    var day = ""
}

func dayKey(_ d: Date) -> String {
    let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
    return "\(c.year!)-\(c.month!)-\(c.day!)"
}

func fmtDuration(_ secs: TimeInterval) -> String {
    let s = max(0, Int(secs))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \(s / 60 % 60)m" }
    return "\(s / 86400)d \(s / 3600 % 24)h"
}

// Apply one check result. Returns the push line when the watch enters `down`
// or a `down` watch comes back, else nil.
func advance(_ st: inout WatchState, name: String, result: CheckResult, now: Date) -> String? {
    let today = dayKey(now)
    if st.day != today { st.day = today; st.recoveriesToday = 0 }
    let old = st.status
    var msg: String?
    switch result {
    case .ok:
        st.failures = 0
        st.lastOK = now
        st.status = "ok"
        if old == "down" {
            st.recoveriesToday += 1
            msg = "\(name) recovered after \(fmtDuration(now.timeIntervalSince(st.failSince ?? st.since)))"
        }
        st.failSince = nil
    case .fail(let e):
        st.failures += 1
        if st.failures == 1 { st.failSince = now }
        st.lastError = e
        st.status = st.failures >= 2 ? "down" : "failing"
        if st.status == "down" && old != "down" { msg = "\(name) is down: \(e)" }
    case .error(let e):
        st.failures = 0
        st.lastError = e
        st.status = "error"
    }
    if st.status != old { st.since = now }
    return msg
}

// MARK: - Output parsers (pure)

// `launchctl print gui/<uid>/<label>`: loaded AND last exit code 0 / never exited.
func launchdResult(code: Int32, output: String) -> CheckResult {
    guard code == 0 else { return .fail("not loaded") }
    guard let line = output.split(separator: "\n").first(where: { $0.contains("last exit code =") }),
          let eq = line.firstIndex(of: "=") else { return .ok }
    let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    if v == "0" || v.hasPrefix("0:") || v.hasPrefix("(never exited)") { return .ok }
    return .fail("last exit code \(v)")
}

// `tailscale serve status --json`: OK when nothing serves on `port` (TCP map key).
func serveResult(code: Int32, output: String, port: String) -> CheckResult {
    guard code == 0 else { return .fail(short(output.isEmpty ? "tailscale serve status failed" : output)) }
    if output.isEmpty { return .ok }
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any] else {
        return .fail("unexpected output: \(short(output))")
    }
    // Background serves sit in TCP; foreground (`tailscale serve` without --bg) in Foreground[session].TCP.
    var maps = [obj["TCP"] as? [String: Any] ?? [:]]
    for case let fg as [String: Any] in (obj["Foreground"] as? [String: Any] ?? [:]).values {
        maps.append(fg["TCP"] as? [String: Any] ?? [:])
    }
    return maps.allSatisfy { $0[port] == nil } ? .ok : .fail("tailscale serve is active on port \(port)")
}

// First line, capped, so errors fit a menu item and a push.
func short(_ s: String) -> String {
    let line = s.split(separator: "\n").first.map(String.init) ?? s
    return line.count > 160 ? String(line.prefix(160)) + "…" : line
}

// MARK: - Checks (not unit-tested)

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private let healthSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForResource = 60
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: cfg, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
}()

// Blocking request with a hard deadline. Returns (status, body, error).
private func fetch(_ req: URLRequest, deadline: Double) -> (Int, Data?, String?) {
    var out: (Int, Data?, String?) = (0, nil, "timeout")
    let sem = DispatchSemaphore(value: 0)
    let task = healthSession.dataTask(with: req) { data, resp, err in
        if let err = err {
            out = (0, nil, err.localizedDescription)
        } else {
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data, nil)
        }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + deadline) == .timedOut {
        task.cancel()
        return (0, nil, "timeout")
    }
    return out
}

func check(_ w: Watch) -> CheckResult {
    switch w.type {
    case "url":
        guard let url = URL(string: w.target), url.scheme != nil else { return .error("bad url") }
        var req = URLRequest(url: url)
        req.timeoutInterval = w.timeout
        let (code, _, err) = fetch(req, deadline: w.timeout + 1)
        if let err = err { return .fail(short(err)) }
        let ok = w.expect.map { $0.contains(code) } ?? (200..<400).contains(code)
        return ok ? .ok : .fail("HTTP \(code)")
    case "port":
        return checkPort(w.target, timeout: w.timeout)
    case "process":
        let (code, _) = Shell.run("/usr/bin/pgrep", ["-x", w.target], timeout: w.timeout)
        return code == 0 ? .ok : .fail("not running")
    case "launchd":
        let (code, out) = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(w.target)"], timeout: w.timeout)
        return launchdResult(code: code, output: out)
    case "tmux":
        let parts = w.target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard !parts[0].isEmpty, parts.count == 1 || !parts[1].isEmpty else { return .error("bad tmux target") }
        guard let tmux = Shell.resolve(["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]) else {
            return .fail("tmux not found")
        }
        // "=name" = exact session match (tmux otherwise prefix-matches).
        let (code, out) = Shell.run(tmux, ["list-windows", "-t", "=" + parts[0], "-F", "#{window_name}"],
                                    timeout: w.timeout)
        if code != 0 { return .fail("no tmux session \(parts[0])") }
        if parts.count == 1 { return .ok }
        return out.split(separator: "\n").contains(Substring(parts[1])) ? .ok : .fail("no tmux window \(parts[1])")
    case "tailscale_serve":
        guard let ts = Shell.tailscale else { return .fail("tailscale not found") }
        let (code, out) = Shell.run(ts, ["serve", "status", "--json"], timeout: w.timeout)
        return serveResult(code: code, output: out, port: w.target)
    case "command":
        let (code, out) = Shell.sh(w.target, timeout: w.timeout)
        if code == 0 { return .ok }
        if code == 124 { return .fail("timeout after \(Int(w.timeout))s") }
        return .fail("exit \(code)" + (out.isEmpty ? "" : ": " + short(out)))
    default:
        return .error("unknown type")
    }
}

private func checkPort(_ target: String, timeout: Double) -> CheckResult {
    guard let p = UInt16(target), let port = NWEndpoint.Port(rawValue: p) else { return .error("bad port") }
    let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    var result: CheckResult?
    let lock = NSLock()
    let sem = DispatchSemaphore(value: 0)
    // First state wins; later callbacks (and ones after the timeout) are ignored.
    func settle(_ r: CheckResult) {
        lock.lock(); defer { lock.unlock() }
        if result == nil { result = r; sem.signal() }
    }
    conn.stateUpdateHandler = { state in
        switch state {
        case .ready: settle(.ok)
        case .waiting(let e), .failed(let e):
            if case .posix(let c) = e { settle(.fail(String(cString: strerror(c.rawValue)))) }
            else { settle(.fail(short("\(e)"))) }
        default: break
        }
    }
    conn.start(queue: .global())
    _ = sem.wait(timeout: .now() + timeout)
    settle(.fail("timeout"))
    conn.cancel()
    lock.lock(); defer { lock.unlock() }
    return result!
}

// MARK: - Engine

final class Health {
    static let shared = Health(
        configPath: ("~/.config/op-guard/watches.json" as NSString).expandingTildeInPath,
        statePath: ("~/.local/state/nodlock/health.json" as NSString).expandingTildeInPath)

    static let host: String = {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, 255)
        return String(cString: buf).split(separator: ".").first.map(String.init) ?? "mac"
    }()

    let configPath: String
    let statePath: String

    private let lock = NSLock()
    private var config: WatchConfig?
    private var configMtime: Date?
    private var configError: String?
    private var configMissing = true
    private var states: [String: WatchState] = [:]
    private var generatedAt = Date()
    private var serverOK: Date?
    private var serverError: String?
    private var outside: [[String: Any]] = []
    private var lastFix: [String: Any]?
    private var fixRunning = false

    init(configPath: String, statePath: String) {
        self.configPath = configPath
        self.statePath = statePath
    }

    func start() {
        Thread.detachNewThread {
            while true {
                self.cycle()
                Thread.sleep(forTimeInterval: TimeInterval(self.interval))
            }
        }
    }

    var interval: Int {
        lock.lock(); defer { lock.unlock() }
        return config?.interval ?? 60
    }

    var isOff: Bool {
        lock.lock(); defer { lock.unlock() }
        return configMissing
    }

    var lastError: String? {
        lock.lock(); defer { lock.unlock() }
        return configMissing ? "no watches.json" : configError
    }

    var watches: [Watch] {
        lock.lock(); defer { lock.unlock() }
        return config?.watches ?? []
    }

    // Re-read watches.json when its mtime changed. Missing = feature off.
    // Bad JSON keeps the last good config and records the error.
    func reloadConfig() {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: configPath))?[.modificationDate] as? Date
        lock.lock(); defer { lock.unlock() }
        guard let mtime = mtime else {
            configMissing = true; config = nil; configError = nil; configMtime = nil; states = [:]
            return
        }
        configMissing = false
        if mtime == configMtime { return }
        configMtime = mtime
        do {
            let c = try parseWatches(try Data(contentsOf: URL(fileURLWithPath: configPath)))
            let old = config?.watches ?? []
            config = c
            configError = nil
            // Keep history only for watches whose check did not change.
            states = states.filter { name, _ in
                guard let n = c.watches.first(where: { $0.name == name }),
                      let o = old.first(where: { $0.name == name }) else { return false }
                return n.sameCheck(o)
            }
        } catch {
            configError = "\(error)"
        }
    }

    // Apply results; returns the push lines for this batch.
    // `startedAt` = when these checks began; a failure seen before a newer pass
    // (e.g. a fix re-check that finished first) is stale and dropped.
    func apply(_ results: [(Watch, CheckResult)], now: Date = Date(), startedAt: Date? = nil) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        for (w, r) in results {
            // Drop results for a watch whose check changed since it ran (e.g. edited during a Fix).
            if let c = config, !c.watches.contains(where: { $0.name == w.name && $0.sameCheck(w) }) { continue }
            var st = states[w.name] ?? WatchState(since: now)
            if r != .ok, let t0 = startedAt, let ok = st.lastOK, ok > t0 { continue }
            if let m = advance(&st, name: w.name, result: r, now: now) { lines.append(m) }
            states[w.name] = st
        }
        generatedAt = now
        return lines
    }

    func cycle() {
        reloadConfig()
        let ws = watches
        let t0 = Date()
        var results = [CheckResult](repeating: .ok, count: ws.count)
        let rlock = NSLock()
        // ponytail: concurrentPerform caps parallelism at the core count; fine for a few dozen watches.
        DispatchQueue.concurrentPerform(iterations: ws.count) { i in
            let r = check(ws[i])
            rlock.lock(); results[i] = r; rlock.unlock()
        }
        push(apply(Array(zip(ws, results)), startedAt: t0))
        heartbeat()
        writeState()
    }

    // One push per batch, text only, same channel as dialog pushes.
    func push(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let title = lines.count == 1 ? lines[0] : "Health: \(lines.count) changes"
        // Max 10 lines: Apple refuses payloads over 4 KB.
        let shown = lines.prefix(10) + (lines.count > 10 ? ["and \(lines.count - 10) more"] : [])
        let body = lines.count == 1 ? "" : shown.joined(separator: "\n")
        FileHandle.standardError.write(Data("nodlock: health push: \(lines.joined(separator: " | "))\n".utf8))
        // Off the cycle thread: a slow push server must never delay checks or the heartbeat.
        DispatchQueue.global().async {
            if Config.shared.apnsEnabled {
                APNs.shared.sendHealth(title: title, body: body)
            } else {
                notifyText(title: title, body: body)
            }
        }
    }

    // MARK: fix

    enum FixStart { case started, unknown, noFix, busy }

    // Runs ONLY the `fix` string from the local watches.json.
    func startFix(name: String) -> FixStart {
        lock.lock()
        guard let w = config?.watches.first(where: { $0.name == name }) else { lock.unlock(); return .unknown }
        guard let fix = w.fix else { lock.unlock(); return .noFix }
        guard !fixRunning else { lock.unlock(); return .busy }
        fixRunning = true
        lock.unlock()

        DispatchQueue.global().async {
            FileHandle.standardError.write(Data("nodlock: fix \(name) -> running: \(fix)\n".utf8))
            let (code, out) = Shell.sh(fix, timeout: 60)
            FileHandle.standardError.write(Data("nodlock: fix \(name) -> exit \(code)\n".utf8))
            self.lock.lock()
            self.lastFix = ["name": name, "at": iso(Date()), "exit": Int(code), "output_tail": String(out.suffix(500))]
            self.fixRunning = false
            self.lock.unlock()
            // ponytail: give the service a moment to come up before the re-check.
            Thread.sleep(forTimeInterval: 3)
            // Only a pass counts: a slow-starting service must not tip `failing` into `down` here.
            let r = check(w)
            if r == .ok { self.push(self.apply([(w, r)])) }
            self.writeState()
        }
        return .started
    }

    // MARK: status server heartbeat

    func heartbeat() {
        let cfg = Config.shared
        guard !cfg.serverURL.isEmpty else { return }
        guard !cfg.serverToken.isEmpty else {
            lock.lock(); serverError = "no OPG_SERVER_TOKEN"; lock.unlock(); return
        }
        let (ok, err, results) = postHeartbeat(url: cfg.serverURL, token: cfg.serverToken)
        lock.lock(); defer { lock.unlock() }
        if ok {
            serverOK = Date(); serverError = nil; outside = results
        } else {
            serverError = err
        }
    }

    // POST one heartbeat (also used by the onboarding "Test" button).
    func postHeartbeat(url base: String, token: String) -> (Bool, String?, [[String: Any]]) {
        var base = base
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/api/heartbeat"), url.host != nil else {
            return (false, "bad server URL", [])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: heartbeatBody())
        req.timeoutInterval = 10
        let (code, data, err) = fetch(req, deadline: 10)
        if let err = err { return (false, short(err), []) }
        guard code == 200 else { return (false, "HTTP \(code)", []) }
        guard let obj = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              obj["ok"] as? Bool == true else { return (false, "bad reply", []) }
        return (true, nil, obj["outside"] as? [[String: Any]] ?? [])
    }

    private func heartbeatBody() -> [String: Any] {
        let snap = snapshot()
        let rows = snap["watches"] as? [[String: Any]] ?? []
        var body: [String: Any] = [
            "host": Health.host,
            "generated_at": snap["generated_at"] ?? NSNull(),
            "summary": snap["summary"] ?? [:],
            "watches": rows.map { ["name": $0["name"]!, "status": $0["status"]!, "last_error": $0["last_error"]!] },
            "outside_targets": watches.filter { $0.type == "url" && $0.outside }.map { w -> [String: Any] in
                var t: [String: Any] = ["name": w.name, "url": w.target]
                if let e = w.expect { t["expect"] = e }
                return t
            },
        ]
        let cfg = Config.shared
        let devices = DeviceStore.shared.tokens()
        if cfg.apnsEnabled && !devices.isEmpty {
            body["apns"] = ["devices": devices, "bundle_id": cfg.apnsBundleID, "env": cfg.apnsEnv]
        }
        return body
    }

    // MARK: snapshot / health.json

    func snapshot() -> [String: Any] {
        let cfg = Config.shared
        lock.lock(); defer { lock.unlock() }
        let rank = ["down": 0, "failing": 1, "error": 2, "ok": 3]
        var counts = ["ok": 0, "failing": 0, "down": 0, "error": 0]
        var rows: [(Int, [String: Any])] = []
        for w in config?.watches ?? [] {
            guard let st = states[w.name] else { continue } // not checked yet
            counts[st.status, default: 0] += 1
            rows.append((rank[st.status] ?? 9, [
                "name": w.name, "type": w.type, "target": w.target, "status": st.status,
                "since": iso(st.since), "last_ok": st.lastOK.map(iso) ?? NSNull(),
                "last_error": st.lastError ?? NSNull(), "consecutive_failures": st.failures,
                "recoveries_today": st.recoveriesToday, "fix": w.fix ?? NSNull(),
                "hint": w.hint ?? NSNull(), "outside": w.outside,
            ]))
        }
        let sorted = rows.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        var server: Any = NSNull()
        if !cfg.serverURL.isEmpty {
            server = ["url": cfg.serverURL, "last_heartbeat_ok": serverOK.map(iso) ?? NSNull(),
                      "error": serverError ?? NSNull()] as [String: Any]
        }
        return [
            "generated_at": iso(generatedAt),
            "host": Health.host,
            "interval_s": config?.interval ?? 60,
            "config_path": (configPath as NSString).abbreviatingWithTildeInPath,
            "config_error": (configMissing ? "no watches.json" : configError) ?? NSNull(),
            "summary": counts,
            "server": server,
            "watches": sorted.map { $0.element.1 },
            "outside_checks": outside,
            "last_fix": lastFix ?? NSNull(),
        ]
    }

    func writeState() {
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        let url = URL(fileURLWithPath: statePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic) // temp file + rename
    }

    // Same text as `nodlockctl health` (keep the two in step).
    func summaryText() -> String {
        healthText(snapshot(), now: Date())
    }
}

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f
}()

func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

// Plain-text rendering of a health.json object. Mirrors nodlockctl's python.
func healthText(_ h: [String: Any], now: Date) -> String {
    let err = h["config_error"] as? String
    if err == "no watches.json" { return "Health: no watches.json (\(h["config_path"] as? String ?? ""))" }
    let s = h["summary"] as? [String: Int] ?? [:]
    let gen = (h["generated_at"] as? String) ?? ""
    var out = ["Health: \(s["down"] ?? 0) down, \(s["failing"] ?? 0) failing, \(s["error"] ?? 0) error, "
        + "\(s["ok"] ?? 0) ok (host \(h["host"] as? String ?? "?"), \(gen.count >= 19 ? String(gen.dropFirst(11).prefix(8)) : gen))"]
    if let err = err { out.append("config error: \(err)") }
    for w in h["watches"] as? [[String: Any]] ?? [] {
        let status = w["status"] as? String ?? "?"
        var line = status.padding(toLength: 8, withPad: " ", startingAt: 0) + " " + (w["name"] as? String ?? "?")
        if status != "ok", let e = w["last_error"] as? String { line += "  \(e)" }
        if let since = (w["since"] as? String).flatMap({ isoFormatter.date(from: $0) }) {
            line += "  \(fmtDuration(now.timeIntervalSince(since)))"
        }
        if let fix = w["fix"] as? String { line += "  fix: \(fix)" }
        out.append(line)
    }
    if let srv = h["server"] as? [String: Any] {
        if let e = srv["error"] as? String {
            out.append("server: error \(e)")
        } else {
            out.append("server: last heartbeat OK \((srv["last_heartbeat_ok"] as? String) ?? "never")")
        }
    }
    for o in h["outside_checks"] as? [[String: Any]] ?? [] {
        var line = "outside: \(o["name"] as? String ?? "?") \(o["status"] as? String ?? "?")"
        if let e = o["last_error"] as? String { line += "  \(e)" }
        out.append(line)
    }
    if let f = h["last_fix"] as? [String: Any] {
        out.append("last fix: \(f["name"] as? String ?? "?") exit \(f["exit"] as? Int ?? -1) at \(f["at"] as? String ?? "?")")
    }
    return out.joined(separator: "\n")
}
