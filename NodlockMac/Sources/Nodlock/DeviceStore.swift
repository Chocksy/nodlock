import Foundation

// One registered iOS device that receives APNs pushes.
struct Device: Codable {
    let token: String
    let platform: String
    let added: Int
}

// Thread-safe, persisted device-token store.
// ~/.config/op-guard/devices.json = array of {token, platform, added}. De-duped
// by token. Perms 0600 like the panel token.
final class DeviceStore {
    static let shared = DeviceStore()

    private let lock = NSLock()
    private let path: String
    private var devices: [Device]

    private init() {
        let dir = ("~/.config/op-guard" as NSString).expandingTildeInPath
        path = (dir as NSString).appendingPathComponent("devices.json")
        devices = DeviceStore.load(path)
    }

    private static func load(_ path: String) -> [Device] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        return (try? JSONDecoder().decode([Device].self, from: data)) ?? []
    }

    // Caller holds the lock.
    private func persist() {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        guard let data = try? JSONEncoder().encode(devices) else { return }
        FileManager.default.createFile(
            atPath: path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path)
    }

    func tokens() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return devices.map { $0.token }
    }

    // Re-reads devices.json from disk so the onboarding wizard shows a live
    // paired-device count even when a phone registers while it is open.
    func liveCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        devices = DeviceStore.load(path)
        return devices.count
    }

    func add(token: String, platform: String) {
        lock.lock(); defer { lock.unlock() }
        guard !token.isEmpty else { return }
        if devices.contains(where: { $0.token == token }) { return } // de-dupe
        devices.append(Device(token: token, platform: platform,
                              added: Int(Date().timeIntervalSince1970)))
        persist()
    }

    func remove(token: String) {
        lock.lock(); defer { lock.unlock() }
        let before = devices.count
        devices.removeAll { $0.token == token }
        if devices.count != before { persist() }
    }
}
