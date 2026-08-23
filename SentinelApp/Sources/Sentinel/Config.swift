import Foundation
import Security

// Config from env AND ~/.config/op-guard/env, matching sentinel.py names.
// Real process environment wins over the file; file provides values when the
// app is launched as a login item with no shell env.
final class Config {
    static let shared = Config()

    let ntfy: String
    let ntfyToken: String
    let topic: String
    let panelURL: String
    let panelToken: String
    let ntfyAttach: Bool
    let port: Int
    let bind: String

    // APNs (token-based auth). Empty = disabled.
    let apnsKeyID: String
    let apnsTeamID: String
    let apnsBundleID: String
    let apnsEnv: String

    // Cloudflare Access service token (per-user). Empty when the file is absent.
    // These ride the pairing QR only, never the ntfy push URL.
    let cfClientId: String
    let cfClientSecret: String

    private init() {
        var values = Config.readEnvFile()
        // Overlay real environment (takes precedence).
        for (k, v) in ProcessInfo.processInfo.environment { values[k] = v }

        ntfy = values["OPG_NTFY"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://ntfy.sh"
        ntfyToken = values["OPG_NTFY_TOKEN"] ?? ""
        topic = values["OPG_TOPIC"] ?? ""
        port = Int(values["SENTINEL_PORT"] ?? "") ?? 8377
        bind = values["SENTINEL_BIND"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"

        // Panel auth token: load from disk or generate + persist (0600).
        let token = Config.loadOrCreateToken()
        panelToken = token

        // Panel URL always carries the token so ntfy actions / menu items work
        // through the auth gate. Base = SENTINEL_URL if set, else the local bind.
        let base = values["SENTINEL_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://\(bind):\(port)"
        let sep = base.contains("?") ? "&" : "?"
        panelURL = "\(base)\(sep)k=\(token)"

        // Screenshot attachment on ntfy pushes is opt-in (default text-only).
        ntfyAttach = Config.boolValue(values["SENTINEL_NTFY_ATTACH"])

        // APNs config (all optional; apnsEnabled below gates actual sends).
        apnsKeyID = values["OPG_APNS_KEY_ID"] ?? ""
        apnsTeamID = values["OPG_APNS_TEAM_ID"] ?? ""
        apnsBundleID = values["OPG_APNS_BUNDLE_ID"] ?? ""
        apnsEnv = values["OPG_APNS_ENV"].flatMap { $0.isEmpty ? nil : $0 } ?? "sandbox"

        // Cloudflare Access service token, if present on disk.
        let cf = Config.readServiceToken()
        cfClientId = cf.clientId
        cfClientSecret = cf.clientSecret
    }

    // QR/pairing payload: panelURL plus the Cloudflare Access service token when
    // both credentials are set. Kept separate from panelURL so ntfy pushes never
    // carry the secret (a browser can't use a service token anyway).
    var pairingPayload: String {
        guard !cfClientId.isEmpty, !cfClientSecret.isEmpty else { return panelURL }
        return "\(panelURL)&cfid=\(cfClientId)&cfsecret=\(cfClientSecret)"
    }

    // sandbox -> api.sandbox.push.apple.com, production -> api.push.apple.com.
    var apnsHost: String {
        apnsEnv.lowercased() == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    // Provider key: ~/.config/op-guard/apns/AuthKey_<KEY_ID>.p8 (PKCS8 EC PEM).
    var apnsKeyPath: String {
        let dir = ("~/.config/op-guard/apns" as NSString).expandingTildeInPath
        return (dir as NSString).appendingPathComponent("AuthKey_\(apnsKeyID).p8")
    }

    // APNs is live only when all IDs are set AND the .p8 key exists on disk.
    var apnsEnabled: Bool {
        !apnsKeyID.isEmpty && !apnsTeamID.isEmpty && !apnsBundleID.isEmpty
            && FileManager.default.fileExists(atPath: apnsKeyPath)
    }

    // Parse KEY=VALUE lines, `export ` prefix allowed, strip surrounding quotes.
    private static func readEnvFile() -> [String: String] {
        let path = ("~/.config/op-guard/env" as NSString).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if val.count >= 2,
               (val.hasPrefix("\"") && val.hasSuffix("\"")) || (val.hasPrefix("'") && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    // Read ~/.config/op-guard/cf-service-token.json -> (client_id, client_secret).
    // Returns empty strings when the file is missing or malformed.
    private static func readServiceToken() -> (clientId: String, clientSecret: String) {
        let path = ("~/.config/op-guard/cf-service-token.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("", "") }
        let id = obj["client_id"] as? String ?? ""
        let secret = obj["client_secret"] as? String ?? ""
        return (id, secret)
    }

    private static func boolValue(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes" || v == "on"
    }

    // Load the panel token from ~/.config/op-guard/panel-token, or generate a
    // 32-hex-char token, write it with 0600 perms, and return it.
    private static func loadOrCreateToken() -> String {
        let dir = ("~/.config/op-guard" as NSString).expandingTildeInPath
        let path = (dir as NSString).appendingPathComponent("panel-token")

        if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        let token = Config.randomHexToken(bytes: 16) // 16 bytes -> 32 hex chars
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        FileManager.default.createFile(
            atPath: path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        // Enforce perms even if the file already existed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return token
    }

    private static func randomHexToken(bytes count: Int) -> String {
        var data = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &data)
        if status != errSecSuccess {
            // Fallback to /dev/urandom if SecRandom fails.
            if let fh = FileHandle(forReadingAtPath: "/dev/urandom") {
                let d = fh.readData(ofLength: count)
                fh.closeFile()
                if d.count == count { data = [UInt8](d) }
            }
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
