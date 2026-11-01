import Foundation
import Network

// Minimal HTTP/1.1 server on 127.0.0.1:PORT via NWListener. No third-party deps.
// Same routes/verbs as the legacy Python daemon.
final class HTTPServer {
    private let port: NWEndpoint.Port
    private let bindHost: String
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nodlock.http", attributes: .concurrent)

    init(host: String, port: Int) {
        self.bindHost = host
        self.port = NWEndpoint.Port(rawValue: UInt16(port)) ?? 8377
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to the loopback endpoint so we never listen on other interfaces.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(bindHost), port: port)

        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    // Accumulate until we have full headers (+ body for POST), then respond.
    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let data = data, !data.isEmpty { buf.append(data) }

            let sep = Data("\r\n\r\n".utf8)
            guard let range = buf.range(of: sep) else {
                if isComplete || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf)
                return
            }

            let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
            let header = String(decoding: headerData, as: UTF8.self)
            let contentLength = self.contentLength(header)
            let bodyStart = range.upperBound
            let have = buf.distance(from: bodyStart, to: buf.endIndex)
            if have < contentLength {
                if isComplete || error != nil { conn.cancel(); return }
                self.receive(conn, buffer: buf)
                return
            }
            let body = buf.subdata(in: bodyStart..<buf.index(bodyStart, offsetBy: contentLength))
            let response = self.route(header: header, body: body)
            conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    private func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    // ---------- routing ----------

    private func route(header: String, body: Data) -> Data {
        let requestLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let tokens = requestLine.split(separator: " ")
        let method = tokens.first.map(String.init) ?? "GET"
        let rawPath = tokens.count > 1 ? String(tokens[1]) : "/"

        // Split the request target into path + query; auth is checked before any
        // handler runs so we never type/click/capture on an unauthorized request.
        let (path, query) = splitPathQuery(rawPath)
        let hasValidQueryToken = tokenMatches(queryValue("k", in: query))
        let hasValidCookie = tokenMatches(cookieValue("sk", in: header))

        guard hasValidQueryToken || hasValidCookie else {
            return httpResponse(status: "401 Unauthorized", contentType: "text/plain",
                                body: Data("unauthorized\n".utf8))
        }

        if method == "GET" {
            // Set the session cookie only when serving the panel page via ?k=.
            let setCookie = hasValidQueryToken && path == "/"
            return handleGET(path: path, setCookie: setCookie)
        } else if method == "POST" {
            return handlePOST(path: path, body: body)
        }
        return httpResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: Data())
    }

    private func handleGET(path: String, setCookie: Bool) -> Data {
        let state = AppState.shared
        let d = state.dialog

        if path.hasPrefix("/status") {
            let cfg = Config.shared
            let locked = screenLocked()
            // Old iOS builds render this as "... 1Password is asking"; new ones read "locked".
            let dialogValue: Any = d.map {
                locked ? "Mac is locked, unlock it first. \($0.owner)" : $0.owner
            } ?? NSNull()
            var obj: [String: Any] = [
                "ok": true,
                "uptime_s": state.uptime,
                "pushes": state.pushes,
                "topic_set": !cfg.topic.isEmpty,
                "panel_url": cfg.panelURL.isEmpty ? NSNull() : cfg.panelURL,
                "dialog": dialogValue,
                "locked": locked,
                "logins": state.loginsList(),
            ]
            // Both keys are omitted on Macs without the switch script, so the
            // phone hides the card instead of showing an empty one.
            if Shell.vpn != nil {
                obj["actions"] = state.actionsList()
                obj["action_pending"] = state.actionPending ?? NSNull()
            }
            let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{\"ok\":true}".utf8)
            return httpResponse(status: "200 OK", contentType: "application/json", body: json)
        }

        if path == "/health" {
            // 404 when there is no watches.json, so the panel hides the card.
            if Health.shared.isOff {
                return httpResponse(status: "404 Not Found", contentType: "application/json",
                                    body: Data("{\"ok\":false,\"error\":\"no watches.json\"}\n".utf8))
            }
            let json = (try? JSONSerialization.data(withJSONObject: Health.shared.snapshot())) ?? Data("{}".utf8)
            return httpResponse(status: "200 OK", contentType: "application/json", body: json)
        }

        if path.hasPrefix("/shot.png") {
            if let d = d, let png = capturePNG(windowID: d.id) {
                return httpResponse(status: "200 OK", contentType: "image/png", body: png)
            }
            return httpResponse(status: "404 Not Found", contentType: "text/plain", body: Data())
        }

        var extra: [String: String] = [:]
        if setCookie {
            // SameSite=Strict keeps forged cross-origin POSTs from carrying the
            // cookie; HttpOnly keeps it out of JS. Closes CSRF.
            extra["Set-Cookie"] = "sk=\(Config.shared.panelToken); Path=/; HttpOnly; SameSite=Strict"
        }
        return httpResponse(status: "200 OK", contentType: "text/html", body: Data(PAGE.utf8),
                            extraHeaders: extra)
    }

    private func handlePOST(path: String, body: Data) -> Data {
        let form = parseForm(body)
        let d = AppState.shared.dialog

        // Device registration for APNs. Auth already enforced in route().
        if path == "/register" {
            let token = (form["token"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return httpResponse(status: "400 Bad Request", contentType: "application/json",
                                    body: Data("{\"ok\":false}\n".utf8))
            }
            let platform = form["platform"].flatMap { $0.isEmpty ? nil : $0 } ?? "ios"
            DeviceStore.shared.add(token: token, platform: platform)
            return httpResponse(status: "200 OK", contentType: "application/json",
                                body: Data("{\"ok\":true}\n".utf8))
        }
        if path == "/unregister" {
            DeviceStore.shared.remove(token: form["token"] ?? "")
            return httpResponse(status: "200 OK", contentType: "application/json",
                                body: Data("{\"ok\":true}\n".utf8))
        }
        if path == "/notify" {
            let url = (form["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                return httpResponse(status: "400 Bad Request", contentType: "application/json",
                                    body: Data("{\"ok\":false}\n".utf8))
            }
            // Record before sending so it's kept even with no registered devices.
            AppState.shared.addLogin(url)
            let host = ProcessInfo.processInfo.hostName
                .split(separator: ".").first.map(String.init) ?? "mac"
            APNs.shared.sendLoginURL(url, host: host)
            return httpResponse(status: "200 OK", contentType: "application/json",
                                body: Data("{\"ok\":true}\n".utf8))
        }
        if path == "/logins/clear" {
            AppState.shared.clearLogins()
            return httpResponse(status: "200 OK", contentType: "application/json",
                                body: Data("{\"ok\":true}\n".utf8))
        }
        if path == "/action" {
            guard let action = ACTIONS.first(where: { $0.id == (form["id"] ?? "") }) else {
                return httpResponse(status: "400 Bad Request", contentType: "application/json",
                                    body: Data("{\"ok\":false,\"error\":\"unknown action\"}\n".utf8))
            }
            guard let vpn = Shell.vpn else {
                return httpResponse(status: "500 Internal Server Error", contentType: "application/json",
                                    body: Data("{\"ok\":false,\"error\":\"vpn tool not found\"}\n".utf8))
            }
            guard AppState.shared.actionPending == nil else {
                return httpResponse(status: "409 Conflict", contentType: "application/json",
                                    body: Data("{\"ok\":false,\"error\":\"busy\"}\n".utf8))
            }
            // Answer immediately: the switch takes seconds and can drop the very
            // link this request came in on. The phone polls /status for the result.
            AppState.shared.setActionPending(action.id)
            DispatchQueue.global().async {
                let (code, _) = Shell.run(vpn, [action.vpnArg], timeout: 60)
                FileHandle.standardError.write(Data("nodlock: action \(action.id) -> exit \(code)\n".utf8))
                AppState.shared.invalidateActions()
                AppState.shared.setActionPending(nil)
            }
            return httpResponse(status: "200 OK", contentType: "application/json",
                                body: Data("{\"ok\":true}\n".utf8))
        }
        if path == "/health/fix" {
            let (status, body): (String, String)
            switch Health.shared.startFix(name: form["name"] ?? "") {
            case .unknown: (status, body) = ("404 Not Found", "{\"ok\":false,\"error\":\"unknown watch\"}")
            case .noFix: (status, body) = ("400 Bad Request", "{\"ok\":false,\"error\":\"no fix\"}")
            case .busy: (status, body) = ("409 Conflict", "{\"ok\":false,\"error\":\"busy\"}")
            case .started: (status, body) = ("200 OK", "{\"ok\":true}")
            }
            return httpResponse(status: status, contentType: "application/json", body: Data((body + "\n").utf8))
        }

        if path == "/click", let d = d {
            let fx = Double(form["fx"] ?? "") ?? 0
            let fy = Double(form["fy"] ?? "") ?? 0
            clickAt(x: d.x + fx * d.w, y: d.y + fy * d.h)
        } else if path == "/type", let text = form["text"], !text.isEmpty {
            if screenLocked() {
                // At the lock screen the text is the Mac login password, not dialog input.
                unlockScreen(password: text, enter: form["enter"] != nil)
                Thread.sleep(forTimeInterval: 1.0)
                FileHandle.standardError.write(Data("nodlock: unlock -> locked=\(screenLocked())\n".utf8))
            } else {
                // No click, no activation: security modals already own key focus.
                typeText(text)
                if form["enter"] != nil {
                    Thread.sleep(forTimeInterval: 0.1)
                    press("return")
                }
            }
        } else if path == "/key", let k = form["k"], KEYCODES[k] != nil {
            press(k)
        }
        // 200, not 303: the iOS client follows redirects and would lose ?k= (401).
        return httpResponse(status: "200 OK", contentType: "application/json",
                            body: Data("{\"ok\":true}\n".utf8))
    }

    // ---------- auth ----------

    private func splitPathQuery(_ raw: String) -> (String, String) {
        if let idx = raw.firstIndex(of: "?") {
            return (String(raw[raw.startIndex..<idx]), String(raw[raw.index(after: idx)...]))
        }
        return (raw, "")
    }

    private func queryValue(_ key: String, in query: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if String(kv[0]) == key {
                return kv.count > 1 ? urlDecode(String(kv[1])) : ""
            }
        }
        return nil
    }

    private func cookieValue(_ key: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "cookie" else { continue }
            let cookies = parts[1].trimmingCharacters(in: .whitespaces)
            for pair in cookies.split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let name = kv[0].trimmingCharacters(in: .whitespaces)
                if name == key {
                    return kv.count > 1 ? String(kv[1]).trimmingCharacters(in: .whitespaces) : ""
                }
            }
        }
        return nil
    }

    // Constant-time compare against the configured panel token.
    private func tokenMatches(_ candidate: String?) -> Bool {
        guard let candidate = candidate else { return false }
        let expected = Array(Config.shared.panelToken.utf8)
        let given = Array(candidate.utf8)
        guard expected.count == given.count, !expected.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count { diff |= expected[i] ^ given[i] }
        return diff == 0
    }

    // ---------- helpers ----------

    private func parseForm(_ body: Data) -> [String: String] {
        let s = String(decoding: body, as: UTF8.self)
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = urlDecode(String(kv[0]))
            let val = kv.count > 1 ? urlDecode(String(kv[1])) : ""
            out[key] = val
        }
        return out
    }

    private func urlDecode(_ s: String) -> String {
        return s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }

    private func httpResponse(status: String, contentType: String, body: Data,
                              extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
