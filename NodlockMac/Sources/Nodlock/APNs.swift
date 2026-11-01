import Foundation
import CryptoKit

// APNs token-based (JWT/ES256) provider. No third-party deps: CryptoKit signs,
// URLSession speaks HTTP/2 to Apple. Pushes carry ONLY a title + owner field —
// never a screenshot or secret. Those stay behind the tailnet panel.
final class APNs {
    static let shared = APNs()

    private let lock = NSLock()
    private var cachedJWT: String?
    private var cachedAt: Date = .distantPast
    private var cachedKeyID: String = ""

    // Base64url, no padding (JWT + raw r||s signature encoding).
    static func base64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: "=", with: "")
        return s
    }

    // Never log a device token or JWT in full.
    static func truncate(_ s: String) -> String {
        s.count <= 12 ? s : "\(s.prefix(8))…\(s.suffix(4))"
    }

    // Load the .p8 PKCS8 EC PEM as a P256 signing key.
    private func loadKey() -> P256.Signing.PrivateKey? {
        let cfg = Config.shared
        guard let pem = try? String(contentsOfFile: cfg.apnsKeyPath, encoding: .utf8) else {
            FileHandle.standardError.write(
                Data("nodlock: apns key not readable at \(cfg.apnsKeyPath)\n".utf8))
            return nil
        }
        do {
            return try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            FileHandle.standardError.write(
                Data("nodlock: apns key parse failed: \(error)\n".utf8))
            return nil
        }
    }

    // Build (or reuse) the provider JWT. APNs allows up to 60 min; regenerate
    // after 50. header {alg:ES256, kid}, claims {iss, iat}. ES256 signature's
    // rawRepresentation is already r||s -> base64url it.
    func providerJWT() -> String? {
        let cfg = Config.shared
        lock.lock(); defer { lock.unlock() }
        if let jwt = cachedJWT, cachedKeyID == cfg.apnsKeyID,
           Date().timeIntervalSince(cachedAt) < 50 * 60 {
            return jwt
        }
        guard let key = loadKey() else { return nil }

        let header: [String: String] = ["alg": "ES256", "kid": cfg.apnsKeyID]
        let claims: [String: Any] = [
            "iss": cfg.apnsTeamID,
            "iat": Int(Date().timeIntervalSince1970),
        ]
        guard let hData = try? JSONSerialization.data(withJSONObject: header),
              let cData = try? JSONSerialization.data(withJSONObject: claims) else { return nil }

        let signingInput = "\(APNs.base64url(hData)).\(APNs.base64url(cData))"
        guard let sig = try? key.signature(for: Data(signingInput.utf8)) else { return nil }
        let jwt = "\(signingInput).\(APNs.base64url(sig.rawRepresentation))"

        cachedJWT = jwt
        cachedAt = Date()
        cachedKeyID = cfg.apnsKeyID
        return jwt
    }

    // HTTP/2 POST to https://<host>/3/device/<token>. Title-only alert.
    // Shared JWT/HTTP2 send path. Builds the authenticated request for one
    // device token and sends the given aps payload. Never logs the full url
    // or full device token.
    private func post(payload: [String: Any], to deviceToken: String, host: String? = nil, isRetry: Bool = false) {
        let cfg = Config.shared
        let apnsHost = host ?? cfg.apnsHost
        guard let jwt = providerJWT() else {
            FileHandle.standardError.write(Data("nodlock: apns no jwt, skipping push\n".utf8))
            return
        }
        guard let url = URL(string: "https://\(apnsHost)/3/device/\(deviceToken)") else { return }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        req.setValue(cfg.apnsBundleID, forHTTPHeaderField: "apns-topic")
        req.setValue("alert", forHTTPHeaderField: "apns-push-type")
        req.setValue("10", forHTTPHeaderField: "apns-priority")
        req.setValue("0", forHTTPHeaderField: "apns-expiration")
        req.httpBody = body
        req.timeoutInterval = 10

        let sem = DispatchSemaphore(value: 0)
        var retryOtherEnv = false
        let task = URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if let error = error {
                FileHandle.standardError.write(Data(
                    "nodlock: apns send failed (\(APNs.truncate(deviceToken))): \(error)\n".utf8))
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let reason = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                FileHandle.standardError.write(Data(
                    "nodlock: apns \(http.statusCode) for \(APNs.truncate(deviceToken)): \(reason)\n".utf8))
                // A token minted by a TestFlight/App Store build only works on the
                // production gateway; an Xcode dev build only on sandbox. Retry once
                // on the other gateway so one Mac serves both kinds of install.
                if !isRetry && reason.contains("BadEnvironment") {
                    retryOtherEnv = true
                    return
                }
                // Self-heal: Apple says this token is dead (app reinstalled / re-paired /
                // uninstalled). Drop it so we stop pushing to a ghost device forever.
                if http.statusCode == 410
                    || reason.contains("Unregistered")
                    || reason.contains("BadDeviceToken")
                    || reason.contains("DeviceTokenNotForTopic") {
                    DeviceStore.shared.remove(token: deviceToken)
                    FileHandle.standardError.write(Data(
                        "nodlock: removed dead device token \(APNs.truncate(deviceToken))\n".utf8))
                }
            }
        }
        task.resume()
        sem.wait()
        if retryOtherEnv {
            let other = apnsHost.contains("sandbox") ? "api.push.apple.com" : "api.sandbox.push.apple.com"
            FileHandle.standardError.write(Data("nodlock: apns BadEnvironment, retrying via \(other)\n".utf8))
            post(payload: payload, to: deviceToken, host: other, isRetry: true)
        }
    }

    func send(title: String, owner: String, to deviceToken: String) {
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": title],
                "sound": "default",
                "interruption-level": "time-sensitive",
            ],
            "owner": owner,
        ]
        post(payload: payload, to: deviceToken)
    }

    func sendToAll(title: String, owner: String) {
        for t in DeviceStore.shared.tokens() {
            send(title: title, owner: owner, to: t)
        }
    }

    // Text-only health push (watch down / recovered). No screenshot, no secrets.
    func sendHealth(title: String, body: String) {
        var alert: [String: Any] = ["title": title]
        if !body.isEmpty { alert["body"] = body }
        let payload: [String: Any] = [
            "aps": ["alert": alert, "sound": "default", "interruption-level": "time-sensitive"],
            "type": "health",
        ]
        for t in DeviceStore.shared.tokens() {
            post(payload: payload, to: t)
        }
    }

    // Push a tappable "Login needed" URL to every registered device via APNs.
    // Never logs the full url or device token.
    func sendLoginURL(_ url: String, host: String) {
        let payload: [String: Any] = [
            "aps": [
                "alert": ["title": "Login needed", "body": "\(host) — tap to open"],
                "sound": "default",
                "interruption-level": "time-sensitive",
            ],
            "type": "login",
            "url": url,
        ]
        for t in DeviceStore.shared.tokens() {
            post(payload: payload, to: t)
        }
    }
}
