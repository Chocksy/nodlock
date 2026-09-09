import Foundation

// One recorded login request pushed to the Mac via POST /notify.
struct LoginRequest: Decodable, Identifiable, Equatable {
    let url: String
    let ts: Int
    var id: String { "\(ts)-\(url)" }
}

// One named action the paired Mac publishes in GET /status. Labels are whatever
// that Mac decides to send; the phone only echoes them back by id.
struct MacAction: Decodable, Identifiable, Equatable {
    let id: String
    let label: String
    let active: Bool
}

// Shape of GET /status (see HTTPServer.handleGET). `dialog` is the prompt owner
// string, or null when no security prompt is on screen.
struct NodlockStatus: Decodable, Equatable {
    var ok: Bool
    var uptime_s: Double?
    var pushes: Int?
    var topic_set: Bool?
    var panel_url: String?
    var dialog: String?
    var locked: Bool?            // absent on older Macs; treat as not locked
    var logins: [LoginRequest]?  // absent on older Macs; treat as []
    var actions: [MacAction]?    // absent on older Macs and in demo; card hidden
    var action_pending: String?  // id of the action the Mac is applying right now

    var hasDialog: Bool { dialog?.isEmpty == false }
    var isLocked: Bool { locked == true }
}

enum NodlockError: Error, LocalizedError {
    case badURL
    case http(Int)
    case noImage

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad server URL"
        case .http(let c): return "Server returned \(c)"
        case .noImage: return "No screenshot available"
        }
    }
}

// One client per pairing. Every request carries ?k=<token>. Bodies are
// x-www-form-urlencoded to match the routes the web panel already POSTs to.
struct NodlockClient: PanelClient {
    let pairing: Pairing

    private var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }

    // Build "<base><path>?k=<token>", appending extra query items when needed.
    private func url(_ path: String, query extra: [String: String] = [:]) throws -> URL {
        guard var comps = URLComponents(string: pairing.base + path) else { throw NodlockError.badURL }
        var items = [URLQueryItem(name: "k", value: pairing.token)]
        for (k, v) in extra { items.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = items
        guard let u = comps.url else { throw NodlockError.badURL }
        return u
    }

    // Attach the Cloudflare Access service-token headers when the pairing carries
    // them. Harmless when Access is not enforced; required once it is. The secret
    // is never logged.
    private func applyAccessHeaders(_ req: inout URLRequest) {
        guard let id = pairing.cfClientId, !id.isEmpty,
              let secret = pairing.cfClientSecret, !secret.isEmpty else { return }
        req.setValue(id, forHTTPHeaderField: "CF-Access-Client-Id")
        req.setValue(secret, forHTTPHeaderField: "CF-Access-Client-Secret")
    }

    private func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    // MARK: - GET

    func status() async throws -> NodlockStatus {
        var req = URLRequest(url: try url("/status"))
        applyAccessHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        try check(resp)
        return try JSONDecoder().decode(NodlockStatus.self, from: data)
    }

    // Returns raw PNG bytes for the current dialog window, or nil when 404 (no dialog).
    func screenshot() async throws -> Data? {
        var req = URLRequest(url: try url("/shot.png", query: ["t": String(Int(Date().timeIntervalSince1970 * 1000))]))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        applyAccessHeaders(&req)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try check(resp)
        return data
    }

    // MARK: - POST (the panel's action routes)

    func type(text: String, enter: Bool) async throws {
        var fields = [("text", text)]
        if enter { fields.append(("enter", "on")) }
        try await post("/type", fields: fields)
    }

    func key(_ k: String) async throws {
        try await post("/key", fields: [("k", k)])
    }

    func click(fx: Double, fy: Double) async throws {
        try await post("/click", fields: [("fx", String(fx)), ("fy", String(fy))])
    }

    func registerPush(deviceTokenHex: String) async throws {
        try await post("/register", fields: [("token", deviceTokenHex), ("platform", "ios")])
    }

    func unregisterPush(deviceTokenHex: String) async throws {
        try await post("/unregister", fields: [("token", deviceTokenHex)])
    }

    func clearLogins() async throws {
        try await post("/logins/clear", fields: [])
    }

    func runAction(id: String) async throws {
        try await post("/action", fields: [("id", id)])
    }

    // The action routes answer 303 redirect (to "/"); treat 2xx and 3xx as success.
    @discardableResult
    private func post(_ path: String, fields: [(String, String)]) async throws -> Data {
        var req = URLRequest(url: try url(path))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyAccessHeaders(&req)
        req.httpBody = formBody(fields)
        let (data, resp) = try await session.data(for: req)
        try check(resp)
        return data
    }

    private func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<400).contains(http.statusCode) else { throw NodlockError.http(http.statusCode) }
    }
}
