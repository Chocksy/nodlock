import Foundation

// Everything the unlock screen needs from a panel backend.
//
// `NodlockClient` is the real thing: HTTP calls to the Mac menu-bar app over
// the network. `DemoClient` fakes the same surface entirely on-device so App
// Review (and anyone curious) can walk the pair -> prompt -> unlock flow
// without a Mac running the companion app.
protocol PanelClient {
    func status() async throws -> NodlockStatus
    func screenshot() async throws -> Data?
    func type(text: String, enter: Bool) async throws
    func key(_ k: String) async throws
    func click(fx: Double, fy: Double) async throws
    func registerPush(deviceTokenHex: String) async throws
    func unregisterPush(deviceTokenHex: String) async throws
    func clearLogins() async throws
    func runAction(id: String) async throws
}
