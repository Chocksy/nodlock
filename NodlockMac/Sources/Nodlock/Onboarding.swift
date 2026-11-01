import AppKit
import SwiftUI
import CoreGraphics
import ApplicationServices

// MARK: - Palette (mirrors the web panel in Panel.swift)

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
    static let sBg = Color(hex: 0x0b0d12)
    static let sCard = Color.white.opacity(0.06)
    static let sLine = Color.white.opacity(0.12)
    static let sTxt = Color(hex: 0xeef1f6)
    static let sDim = Color(hex: 0x9aa4b2)
    static let sAccent = Color(hex: 0x4c8dff)
    static let sAccent2 = Color(hex: 0x7b5cff)
    static let sOk = Color(hex: 0x2fd27a)
    static let sWarn = Color(hex: 0xffb020)
    static let sDanger = Color(hex: 0xff5c6c)
}

// MARK: - Steps

private enum Step: Int, CaseIterable {
    case welcome, permissions, reachability, pairing, server, done

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .permissions: return "Permissions"
        case .reachability: return "Reachability"
        case .pairing: return "Pair phone"
        case .server: return "Status server"
        case .done: return "Done"
        }
    }

    var icon: String {
        switch self {
        case .welcome: return "sparkles"
        case .permissions: return "lock.shield"
        case .reachability: return "antenna.radiowaves.left.and.right"
        case .pairing: return "qrcode"
        case .server: return "server.rack"
        case .done: return "checkmark.seal"
        }
    }
}

// Redirect-free URLSession delegate: NoRedirectDelegate lives in Health.swift.
// Cloudflare Access answers an unauthenticated request with a 302 to the login
// page, so we stop at the first response and judge the code ourselves.

// MARK: - Live state model

fileprivate final class OnboardingModel: ObservableObject {
    @Published var step: Step = .welcome

    @Published var screenRecording = false
    @Published var accessibility = false
    @Published var panelReachable = false
    @Published var panelDetail = "Checking…"
    @Published var devicesPaired = 0

    @Published var pushResult = ""
    @Published var pushBusy = false

    // Status server step. Prefilled from the env file when already set up.
    // Editing either field after a Test clears its result.
    @Published var serverToken = Config.shared.serverToken {
        didSet { if serverToken != oldValue { serverResult = "" } }
    }
    @Published var serverURL = Config.shared.serverURL.isEmpty ? "http://nodlock-server:8080" : Config.shared.serverURL {
        didSet { if serverURL != oldValue { serverResult = "" } }
    }
    @Published var serverResult = ""
    @Published var serverBusy = false
    @Published var lastTestOK: Date?
    // From Health while the Status server step is open.
    @Published var heartbeatOK: Date?
    @Published var heartbeatError: String?

    private var timer: Timer?
    private var checkingReachability = false

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg,
                          delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    }()

    // APNs is config-only, so it is cheap enough to read every refresh.
    var apnsConfigured: Bool { Config.shared.apnsEnabled }

    var apnsDetail: String {
        let cfg = Config.shared
        guard cfg.apnsEnabled else {
            return "APNs not configured — set OPG_APNS_TEAM_ID / OPG_APNS_KEY_ID / "
                 + "OPG_APNS_BUNDLE_ID and place the .p8 at ~/.config/op-guard/apns/"
        }
        let key = cfg.apnsKeyID.count > 4 ? "…\(cfg.apnsKeyID.suffix(4))" : cfg.apnsKeyID
        return "APNs configured (Team \(cfg.apnsTeamID), Key \(key))"
    }

    var panelHost: String {
        URL(string: Config.shared.panelURL)?.host ?? Config.shared.bind
    }

    // Per-step "green check" logic. APNs and pairing are optional, so they do
    // not gate the reachability or pairing rail rows.
    func satisfied(_ step: Step) -> Bool {
        switch step {
        case .welcome: return true
        case .permissions: return screenRecording && accessibility
        case .reachability: return panelReachable
        case .pairing: return devicesPaired > 0
        case .server: return !Config.shared.serverURL.isEmpty
        case .done: return allGreen
        }
    }

    // Pairing is skippable: the browser panel works on its own.
    var allGreen: Bool {
        screenRecording && accessibility && panelReachable
    }

    func startPolling() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        // Cheap, main-thread checks.
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
        devicesPaired = DeviceStore.shared.liveCount()
        if step == .server { readHeartbeat() }

        // Network check off the main thread; publish on main.
        guard !checkingReachability else { return }
        checkingReachability = true
        let host = panelHost
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let (ok, detail) = OnboardingModel.checkPanel(host: host)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.panelReachable = ok
                self.panelDetail = detail
                self.checkingReachability = false
            }
        }
    }

    // <panelURL base>/status?k=<panelToken>
    private static func statusURL() -> URL? {
        let cfg = Config.shared
        guard var comps = URLComponents(string: cfg.panelURL) else { return nil }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/status"
        comps.queryItems = [URLQueryItem(name: "k", value: cfg.panelToken)]
        return comps.url
    }

    private static func checkPanel(host: String) -> (Bool, String) {
        guard let url = statusURL() else { return (false, "Panel URL is not valid.") }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 4

        var code = -1
        var failed = false
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { _, resp, error in
            defer { sem.signal() }
            if error != nil { failed = true; return }
            code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        }.resume()
        if sem.wait(timeout: .now() + 6) == .timedOut { failed = true }

        if failed || code < 0 {
            return (false, "Can't reach panel — is the tunnel / Mac app running?")
        }
        // 302/401 come from Cloudflare Access when the request carries no
        // service token. The tunnel is up, which is what this row measures.
        if code == 200 || code == 302 || code == 401 {
            return (true, "Panel reachable via \(host)")
        }
        return (false, "HTTP \(code) from \(host) — is the tunnel / Mac app running?")
    }

    // MARK: - Grant / open actions

    func grantScreenRecording() {
        CGRequestScreenCaptureAccess()
        OnboardingModel.openSettings("com.apple.preference.security?Privacy_ScreenCapture")
    }

    func grantAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        OnboardingModel.openSettings("com.apple.preference.security?Privacy_Accessibility")
    }

    // MARK: - Test push

    func sendTestPush() {
        guard !pushBusy else { return }
        guard Config.shared.apnsEnabled else {
            pushResult = "APNs not configured"
            return
        }
        let count = DeviceStore.shared.liveCount()
        devicesPaired = count
        guard count > 0 else {
            pushResult = "No paired devices yet"
            return
        }
        pushBusy = true
        pushResult = "Sending…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            APNs.shared.sendToAll(title: "Nodlock test", owner: "test")
            DispatchQueue.main.async {
                self?.pushBusy = false
                self?.pushResult = "Sent to \(count) device(s)"
            }
        }
    }

    // MARK: - Status server

    // The server reuses this Mac's ntfy topic.
    var serverEnvBlock: String {
        "NODLOCK_TOKEN=\(trimmedToken)\nTS_AUTHKEY=\nNTFY_TOPIC=\(Config.shared.topic)"
    }

    var trimmedToken: String { serverToken.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedURL: String { serverURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    var serverTestOK: Bool { serverResult == "Connected" }

    // Config strips trailing slashes from OPG_SERVER_URL, so compare the same way.
    var serverFieldsSaved: Bool {
        var url = trimmedURL
        while url.hasSuffix("/") { url.removeLast() }
        return trimmedToken == Config.shared.serverToken && url == Config.shared.serverURL
    }

    // Newest good heartbeat: the running app's (within 3 min) or the last Test.
    var lastGoodHeartbeat: Date? {
        let live = heartbeatOK.flatMap { Date().timeIntervalSince($0) < 180 ? $0 : nil }
        let test = serverTestOK ? lastTestOK : nil
        return [live, test].compactMap { $0 }.max()
    }

    func readHeartbeat() {
        let srv = Health.shared.snapshot()["server"] as? [String: Any]
        heartbeatOK = (srv?["last_heartbeat_ok"] as? String).flatMap { OnboardingModel.isoParser.date(from: $0) }
        heartbeatError = srv?["error"] as? String
    }

    private static let isoParser = ISO8601DateFormatter()

    func generateServerToken() {
        serverToken = Config.randomHexToken(bytes: 16) // 32 hex chars, clears serverResult
    }

    func copyServerEnv() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serverEnvBlock, forType: .string)
    }

    func testServer() {
        guard !serverBusy else { return }
        serverBusy = true
        serverResult = "Testing…"
        let (url, token) = (trimmedURL, trimmedToken)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, err, _) = Health.shared.postHeartbeat(url: url, token: token)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.serverBusy = false
                // Fields edited while the test ran: the result is for old values.
                guard self.trimmedURL == url && self.trimmedToken == token else { self.serverResult = ""; return }
                self.serverResult = ok ? "Connected" : (err ?? "failed")
                if ok { self.lastTestOK = Date() }
            }
        }
    }

    // Writes OPG_SERVER_URL / OPG_SERVER_TOKEN, then restarts (Config loads once).
    func saveServer() {
        do {
            try Config.writeEnv([("OPG_SERVER_URL", trimmedURL), ("OPG_SERVER_TOKEN", trimmedToken)])
        } catch {
            serverResult = "Could not write the env file: \(error.localizedDescription)"
            return
        }
        (NSApp.delegate as? AppDelegate)?.restart()
    }

    static func openSettings(_ tail: String) {
        if let url = URL(string: "x-apple.systempreferences:\(tail)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Reusable views

private struct GhostButtonStyle: ButtonStyle {
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 12 : 13, weight: .semibold))
            .foregroundColor(.sTxt)
            .padding(.horizontal, small ? 10 : 14).padding(.vertical, small ? 4 : 8)
            .background(RoundedRectangle(cornerRadius: small ? 8 : 10).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: small ? 8 : 10).stroke(Color.sLine, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.sAccent, Color(hex: 0x3b7bff)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            .shadow(color: Color.sAccent.opacity(0.4), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct CheckBadge: View {
    let ok: Bool
    var body: some View {
        ZStack {
            Circle().fill(ok ? Color.sOk.opacity(0.18) : Color.white.opacity(0.05))
            Image(systemName: ok ? "checkmark" : "circle")
                .font(.system(size: ok ? 13 : 10, weight: .bold))
                .foregroundColor(ok ? .sOk : .sDim)
        }
        .frame(width: 30, height: 30)
        .overlay(Circle().stroke(ok ? Color.sOk.opacity(0.5) : Color.sLine, lineWidth: 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: ok)
    }
}

private struct OptionalTag: View {
    var body: some View {
        Text("optional")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.sDim)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(Color.sLine, lineWidth: 1))
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let ok: Bool
    var optional: Bool = false
    var danger: Bool = false
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckBadge(ok: ok)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.sTxt)
                    if optional { OptionalTag() }
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(ok ? .sDim : (danger ? .sDanger : .sDim))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let t = actionTitle, let a = action, !ok {
                Button(t, action: a).buttonStyle(GhostButtonStyle())
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.sCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.sLine, lineWidth: 1))
    }
}

private struct StepHeader<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(LinearGradient(colors: [.sAccent, .sAccent2],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Color.sAccent.opacity(0.4), radius: 8, y: 3)
                Text(title).font(.system(size: 22, weight: .bold)).foregroundColor(.sTxt)
                Spacer(minLength: 8)
                accessory()
            }
            Text(subtitle).font(.system(size: 13)).foregroundColor(.sDim)
        }
    }
}

extension StepHeader where Accessory == EmptyView {
    init(icon: String, title: String, subtitle: String) {
        self.init(icon: icon, title: title, subtitle: subtitle, accessory: { EmptyView() })
    }
}

// Numbered checklist row: number in a circle, green check when done.
private struct ChecklistRow<Content: View>: View {
    let n: Int
    let done: Bool
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(done ? Color.sOk : Color.clear)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(hex: 0x05210f))
                } else {
                    Text("\(n)").font(.system(size: 11, weight: .semibold)).foregroundColor(.sAccent)
                }
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().stroke(done ? Color.sOk : Color.sAccent, lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
        .overlay(Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1), alignment: .top)
    }
}

// MARK: - Left rail

private struct RailRow: View {
    let step: Step
    let index: Int
    let current: Bool
    let satisfied: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(current ? Color.sAccent.opacity(0.22) : Color.white.opacity(0.05))
                if satisfied {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.sOk)
                } else {
                    Text("\(index + 1)").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(current ? .sAccent : .sDim)
                }
            }
            .frame(width: 26, height: 26)
            .overlay(Circle().stroke(satisfied ? Color.sOk.opacity(0.5)
                                     : (current ? Color.sAccent.opacity(0.6) : Color.sLine), lineWidth: 1))
            Text(step.title)
                .font(.system(size: 13, weight: current ? .semibold : .regular))
                .foregroundColor(current ? .sTxt : .sDim)
            Spacer()
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(current ? Color.white.opacity(0.05) : .clear))
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: satisfied)
    }
}

// MARK: - Root view

fileprivate struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            background
            HStack(spacing: 0) {
                rail
                Divider().overlay(Color.sLine)
                content
            }
        }
        .frame(width: 760, height: 540)
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        ZStack {
            Color.sBg
            RadialGradient(colors: [Color.sAccent.opacity(0.18), .clear],
                           center: .init(x: 0.18, y: -0.05), startRadius: 0, endRadius: 620)
            RadialGradient(colors: [Color.sOk.opacity(0.10), .clear],
                           center: .init(x: 1.0, y: 0.02), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("N")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(LinearGradient(colors: [.sAccent, .sAccent2],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .shadow(color: Color.sAccent.opacity(0.4), radius: 8, y: 3)
                Text("Nodlock").font(.system(size: 16, weight: .bold)).foregroundColor(.sTxt)
            }
            .padding(.bottom, 18)

            ForEach(Array(Step.allCases.enumerated()), id: \.element) { idx, step in
                RailRow(step: step, index: idx,
                        current: model.step == step,
                        satisfied: model.satisfied(step))
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { model.step = step } }
            }
            Spacer()
            Text("Re-open from the menu\nbar anytime.")
                .font(.system(size: 11)).foregroundColor(.sDim)
        }
        .padding(20)
        .frame(width: 210)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            stepBody
            Spacer(minLength: 0)
            navBar
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var stepBody: some View {
        switch model.step {
        case .welcome: welcomeStep
        case .permissions: permissionsStep
        case .reachability: reachabilityStep
        case .pairing: pairingStep
        case .server: serverStep
        case .done: doneStep
        }
    }

    // MARK: Step 1 — Welcome
    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(icon: Step.welcome.icon, title: "Welcome to Nodlock",
                       subtitle: "Approve Mac security prompts from your phone.")
            Text("Nodlock watches for macOS unlock and permission prompts, then pushes them to your iPhone so you can approve, type a password, or tap a button from anywhere. The same panel opens in any browser.")
                .font(.system(size: 14)).foregroundColor(.sTxt).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(["Nothing is stored", "Your own tunnel", "Push straight to your iPhone"], id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 12, weight: .medium)).foregroundColor(.sDim)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.sCard))
                        .overlay(Capsule().stroke(Color.sLine, lineWidth: 1))
                }
            }
        }
    }

    // MARK: Step 2 — Permissions
    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(icon: Step.permissions.icon, title: "Grant permissions",
                       subtitle: "Nodlock needs two macOS permissions to see and act on prompts.")
            StatusRow(title: "Screen Recording",
                      detail: model.screenRecording ? "Granted" : "Lets Nodlock screenshot the prompt.",
                      ok: model.screenRecording,
                      actionTitle: "Grant", action: model.grantScreenRecording)
            StatusRow(title: "Accessibility",
                      detail: model.accessibility ? "Granted" : "Lets Nodlock type and click for you.",
                      ok: model.accessibility,
                      actionTitle: "Grant", action: model.grantAccessibility)
            Text("After granting in System Settings, this window updates automatically.")
                .font(.system(size: 12)).foregroundColor(.sDim)
        }
    }

    // MARK: Step 3 — Reachability
    private var reachabilityStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(icon: Step.reachability.icon, title: "Check reachability",
                       subtitle: "Your phone and browser reach the panel over the tunnel.")
            StatusRow(title: "Panel reachable",
                      detail: model.panelDetail,
                      ok: model.panelReachable,
                      danger: true)
            StatusRow(title: "iPhone push (APNs)",
                      detail: model.apnsDetail,
                      ok: model.apnsConfigured,
                      optional: true)
            if !model.apnsConfigured {
                Text("Without APNs the panel still works in a browser, you just get no phone alerts.")
                    .font(.system(size: 12)).foregroundColor(.sWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 4 — Pair phone
    private var pairingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(icon: Step.pairing.icon, title: "Pair your phone",
                       subtitle: "Optional. Skip it and use the browser panel instead.")
            HStack(alignment: .top, spacing: 22) {
                Image(nsImage: QRCode.image(from: Config.shared.pairingPayload, side: 170))
                    .interpolation(.none)
                    .resizable().frame(width: 170, height: 170)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.sLine, lineWidth: 1))
                VStack(alignment: .leading, spacing: 10) {
                    pairStepLine(1, "Build the Nodlock iOS app from NodlockiOS/ in Xcode with your own Apple team (see NodlockiOS/README.md)")
                    pairStepLine(2, "Run it on your iPhone")
                    pairStepLine(3, "Scan this QR")
                    HStack(spacing: 8) {
                        CheckBadge(ok: model.devicesPaired > 0)
                        Text("Devices paired: \(model.devicesPaired)")
                            .font(.system(size: 14, weight: .semibold)).foregroundColor(.sTxt)
                    }
                    .padding(.top, 2)
                    testPushControls
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Text("You can also use the browser panel. Pairing is not required.")
                    .font(.system(size: 12)).foregroundColor(.sDim)
                Spacer(minLength: 8)
                if !Config.shared.topic.isEmpty {
                    Button("Copy ntfy topic") { (NSApp.delegate as? AppDelegate)?.copyTopic() }
                        .buttonStyle(GhostButtonStyle(small: true))
                }
            }
        }
    }

    private func pairStepLine(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "\(n).circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.sAccent)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13)).foregroundColor(.sTxt)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var testPushControls: some View {
        HStack(spacing: 10) {
            Button(model.pushBusy ? "Sending…" : "Send test push") { model.sendTestPush() }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.pushBusy)
            if !model.pushResult.isEmpty {
                Text(model.pushResult)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(model.pushResult.hasPrefix("Sent") ? .sOk : .sWarn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Step 5 — Status server (optional)
    private var serverStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(icon: Step.server.icon, title: "Status server",
                       subtitle: "Optional. Checks your sites from another machine and tells you when this Mac goes silent.") {
                serverPill
            }
            VStack(alignment: .leading, spacing: 0) {
                ChecklistRow(n: 1, done: model.lastGoodHeartbeat != nil) {
                    stepTitle("Tag and rules in Tailscale", link: "Open ↗",
                              url: "https://login.tailscale.com/admin/acls")
                    stepHint("tag:nodlock may reach this Mac on 443; you may reach the tag on 8080. Skip if your policy allows all.")
                }
                ChecklistRow(n: 2, done: model.lastGoodHeartbeat != nil) {
                    stepTitle("Reusable auth key with tag:nodlock", link: "Open ↗",
                              url: "https://login.tailscale.com/admin/settings/keys")
                }
                ChecklistRow(n: 3, done: !model.trimmedToken.isEmpty) {
                    stepTitle("Shared token")
                    HStack(spacing: 8) {
                        TextField("Token", text: $model.serverToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button("Generate") { model.generateServerToken() }
                            .buttonStyle(GhostButtonStyle(small: true))
                        Button("Copy server env") { model.copyServerEnv() }
                            .buttonStyle(GhostButtonStyle(small: true))
                            .disabled(model.trimmedToken.isEmpty)
                    }
                }
                ChecklistRow(n: 4, done: model.lastGoodHeartbeat != nil) {
                    stepTitle("Deploy server/compose.yaml", link: "Guide ↗",
                              url: "https://github.com/Chocksy/nodlock/blob/main/server/README.md")
                    stepHint("Paste the env from step 3. Your ntfy topic is already in it.")
                }
                ChecklistRow(n: 5, done: model.serverTestOK) {
                    stepTitle("Address")
                    HStack(spacing: 8) {
                        TextField("Server address", text: $model.serverURL)
                            .textFieldStyle(.roundedBorder)
                        Button(model.serverBusy ? "Testing…" : "Test") { model.testServer() }
                            .buttonStyle(GhostButtonStyle(small: true))
                            .disabled(model.serverBusy || model.trimmedToken.isEmpty)
                    }
                    if !model.serverResult.isEmpty && !model.serverTestOK {
                        stepHint(model.serverResult, color: .sWarn)
                    }
                }
            }
            Text("Saving writes OPG_SERVER_URL and OPG_SERVER_TOKEN to ~/.config/op-guard/env and restarts Nodlock.")
                .font(.system(size: 11)).foregroundColor(.sDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.readHeartbeat() }
    }

    // Re-rendered by the model's 1.5 s refresh, which also re-reads Health.
    private var serverPill: some View {
        let good = model.lastGoodHeartbeat
        var text = "Not connected"
        if let good = good {
            text = "Connected · heartbeat \(fmtDuration(Date().timeIntervalSince(good))) ago"
        } else if let e = model.heartbeatError {
            text += " · \(e)"
        }
        let color: Color = good != nil ? .sOk : .sWarn
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundColor(color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .frame(maxWidth: 260, alignment: .trailing)
    }

    private func stepTitle(_ title: String, link: String? = nil, url: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.sTxt)
            if let link = link, let url = url.flatMap(URL.init(string:)) {
                Link(link, destination: url).font(.system(size: 12))
            }
        }
    }

    private func stepHint(_ text: String, color: Color = Color(hex: 0x7d8794)) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundColor(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Step 6 — Done
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(icon: Step.done.icon, title: model.allGreen ? "You're all set" : "Almost there",
                       subtitle: model.allGreen ? "Everything required checks out."
                                                : "Finish the unchecked items above, then you're ready.")
            VStack(spacing: 10) {
                summaryRow("Screen Recording", model.screenRecording)
                summaryRow("Accessibility", model.accessibility)
                summaryRow("Panel reachable", model.panelReachable)
                summaryRow("iPhone push (APNs)", model.apnsConfigured, optional: true)
                summaryRow("Phone paired", model.devicesPaired > 0, optional: true)
            }
            testPushControls
            Text("Re-open setup anytime from the menu bar: Setup…")
                .font(.system(size: 12)).foregroundColor(.sDim)
        }
    }

    private func summaryRow(_ title: String, _ ok: Bool, optional: Bool = false) -> some View {
        HStack(spacing: 12) {
            CheckBadge(ok: ok)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(.sTxt)
            if optional { OptionalTag() }
            Spacer()
            Text(ok ? "Ready" : (optional ? "Skipped" : "Pending"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(ok ? .sOk : (optional ? .sDim : .sWarn))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.sCard))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sLine, lineWidth: 1))
    }

    // MARK: Nav bar
    private var navBar: some View {
        HStack {
            if model.step != .welcome {
                Button("Back") { goTo(offset: -1) }.buttonStyle(GhostButtonStyle())
            }
            Spacer()
            switch model.step {
            case .welcome:
                Button("Get Started") { goTo(offset: 1) }.buttonStyle(PrimaryButtonStyle())
            case .done:
                Button("Finish") { onFinish() }.buttonStyle(PrimaryButtonStyle())
            case .server:
                if model.serverTestOK && !model.serverFieldsSaved {
                    Button("Save and finish") { model.saveServer() }.buttonStyle(PrimaryButtonStyle())
                } else if model.serverFieldsSaved && model.lastGoodHeartbeat != nil {
                    Button("Next") { goTo(offset: 1) }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Skip") { goTo(offset: 1) }.buttonStyle(PrimaryButtonStyle())
                }
            case .pairing:
                Button("Skip") { goTo(offset: 1) }.buttonStyle(PrimaryButtonStyle())
            default:
                Button("Next") { goTo(offset: 1) }.buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func goTo(offset: Int) {
        let next = min(max(model.step.rawValue + offset, 0), Step.allCases.count - 1)
        withAnimation(.easeInOut(duration: 0.2)) { model.step = Step(rawValue: next) ?? model.step }
    }
}

// MARK: - Window controller (mirrors QRWindowController pattern)

final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?
    private let model = OnboardingModel()

    private override init() { super.init() }

    func show() {
        model.step = .welcome
        model.startPolling()

        if let window = window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let root = OnboardingView(model: model, onFinish: { [weak self] in self?.finish() })
        let hosting = NSHostingController(rootView: root)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.contentViewController = hosting
        win.title = "Nodlock Setup"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.backgroundColor = NSColor(red: 0x0b/255.0, green: 0x0d/255.0, blue: 0x12/255.0, alpha: 1)
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        window = win

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "didCompleteOnboarding")
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }
}
