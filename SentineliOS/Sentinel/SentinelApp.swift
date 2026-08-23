import SwiftUI
import UserNotifications
import UIKit

@main
struct SentinelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

// Central observable state shared between SwiftUI and the UIKit app delegate.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var pairing: Pairing?
    // Set true when the user taps a push; RootView re-runs the Face ID gate and
    // drops straight onto the unlock screen.
    @Published var pendingDeepLink = false

    // Set when the Face ID gate had to be skipped in demo mode (no enrolled
    // biometrics on the device); the unlock screen shows it as a note.
    @Published var demoAuthNote: String?

    private let deviceTokenKey = "apnsDeviceTokenHex"

    // The real Mac, or the on-device fake when paired to the reviewer demo.
    var client: (any PanelClient)? {
        guard let pairing else { return nil }
        if pairing.isDemo { return DemoClient.shared }
        return SentinelClient(pairing: pairing)
    }

    var isPaired: Bool { pairing != nil }

    var isDemo: Bool { pairing?.isDemo == true }

    private init() {
        pairing = KeychainStore.load()
    }

    // MARK: - Pairing

    // Parse a scanned/pasted panel URL of the form:
    //   http://<host>:8377?k=<token>[&cfid=<id>&cfsecret=<secret>]
    // cfid/cfsecret carry the Cloudflare Access service token when present.
    static func parse(_ raw: String) -> Pairing? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme,
              let host = comps.host,
              let token = comps.queryItems?.first(where: { $0.name == "k" })?.value,
              !token.isEmpty
        else { return nil }
        var base = "\(scheme)://\(host)"
        if let port = comps.port { base += ":\(port)" }
        let cfid = comps.queryItems?.first(where: { $0.name == "cfid" })?.value
        let cfsecret = comps.queryItems?.first(where: { $0.name == "cfsecret" })?.value
        return Pairing(base: base, token: token, cfClientId: cfid, cfClientSecret: cfsecret)
    }

    @discardableResult
    func pair(from raw: String) -> Bool {
        guard let pairing = AppModel.parse(raw) else { return false }
        KeychainStore.save(pairing)
        self.pairing = pairing
        // Ask for push and (re)register the current device token with this Mac.
        requestPushAuthorization()
        registerCurrentDeviceToken()
        return true
    }

    // Pair with the on-device demo: no Mac, no network, no push. Stored in the
    // Keychain like any other pairing so unpair/relaunch behave identically.
    func startDemo() {
        let pairing = Pairing(base: Pairing.demoBase, token: Pairing.demoToken,
                              cfClientId: nil, cfClientSecret: nil)
        DemoClient.shared.reset()
        demoAuthNote = nil
        KeychainStore.save(pairing)
        self.pairing = pairing
    }

    func unpair() {
        // Best-effort unregister so the Mac stops pushing to this device.
        if let client, let hex = UserDefaults.standard.string(forKey: deviceTokenKey) {
            Task { try? await client.unregisterPush(deviceTokenHex: hex) }
        }
        KeychainStore.clear()
        pairing = nil
        // Nothing of the demo run survives an unpair.
        DemoClient.shared.reset()
        demoAuthNote = nil
    }

    // MARK: - Push

    func requestPushAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // Called by the app delegate when APNs hands us a token.
    func didReceiveDeviceToken(_ hex: String) {
        let previous = UserDefaults.standard.string(forKey: deviceTokenKey)
        UserDefaults.standard.set(hex, forKey: deviceTokenKey)
        // Re-register whenever the token changed or we have a fresh pairing.
        if previous != hex || pairing != nil {
            registerCurrentDeviceToken()
        }
    }

    private func registerCurrentDeviceToken() {
        guard let client,
              let hex = UserDefaults.standard.string(forKey: deviceTokenKey),
              !hex.isEmpty
        else { return }
        Task { try? await client.registerPush(deviceTokenHex: hex) }
    }
}

// UIKit delegate: owns APNs callbacks and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // If already paired, make sure we are registered for remote notifications.
        // The demo pairing never talks to a Mac, so it never needs push.
        if AppModel.shared.isPaired, !AppModel.shared.isDemo {
            AppModel.shared.requestPushAuthorization()
        }
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        AppModel.shared.didReceiveDeviceToken(hex)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Simulator has no APNs; this is expected there. Surface nothing to the user.
        NSLog("Sentinel: APNs registration failed: \(error.localizedDescription)")
    }

    // Foreground push: still show the banner so the user can tap through.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    // Tapped a push: deep-link into the unlock screen (behind the Face ID gate).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // A "login" push carries a URL: opening it in the browser IS the action,
        // so bypass the unlock deep-link and open the URL directly. (Never log it.)
        if let type = info["type"] as? String, type == "login",
           let urlString = info["url"] as? String,
           let url = URL(string: urlString) {
            await MainActor.run { UIApplication.shared.open(url) }
            return
        }
        await MainActor.run { AppModel.shared.pendingDeepLink = true }
    }
}
