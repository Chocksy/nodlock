import Foundation
import Security

// Pairing = the Mac we talk to. `base` is the full origin including scheme + port
// (e.g. "https://sentinel.example.com"); `token` is the panel token that
// must ride on every request as ?k=<token>.
struct Pairing: Codable, Equatable {
    var base: String
    var token: String
    // Cloudflare Access service-token credentials, delivered via the pairing QR
    // only. nil for pairings created before Access was introduced.
    var cfClientId: String?
    var cfClientSecret: String?

    // The reviewer demo pairing: no Mac, no network, everything faked on-device
    // by DemoClient. See PairingView's "Try a demo".
    static let demoBase = "demo://local"
    static let demoToken = "demo"

    var isDemo: Bool { base == Pairing.demoBase }

    // A short, human-friendly label for the paired host (drops scheme + port).
    var displayHost: String {
        if isDemo { return "the demo Mac" }
        return URLComponents(string: base)?.host ?? base
    }
}

// Minimal Keychain wrapper for a single JSON blob. Nothing sensitive touches
// UserDefaults. The panel token is a bearer credential, so it lives here.
enum KeychainStore {
    // Keyed to the app's own bundle id, so it follows whatever id you build with.
    private static let service = Bundle.main.bundleIdentifier ?? "com.example.sentinel.ios"
    private static let account = "pairing"

    static func save(_ pairing: Pairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add.merge(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func load() -> Pairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let pairing = try? JSONDecoder().decode(Pairing.self, from: data)
        else { return nil }
        return pairing
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
