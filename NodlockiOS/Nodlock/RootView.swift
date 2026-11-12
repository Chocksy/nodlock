import SwiftUI
import LocalAuthentication

// Top-level switch: pair first, then gate the unlock screen behind Face ID.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.background
            if model.isPaired {
                BiometricGate {
                    TabView {
                        UnlockView()
                            .background(Theme.background)
                            .tabItem { Label("Unlock", systemImage: "key.viewfinder") }
                        StatusView()
                            .background(Theme.background)
                            .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                    }
                    .tint(Theme.accent)
                }
            } else {
                PairingView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isPaired)
    }
}

// Requires LocalAuthentication (Face ID / Touch ID, passcode fallback) before it
// reveals its content. Nothing sensitive (no keystrokes, no unlock UI) renders
// until the user passes the gate.
struct BiometricGate<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ViewBuilder var content: Content

    @State private var authenticated = false
    @State private var authInFlight = false
    @State private var errorText: String?

    var body: some View {
        Group {
            if authenticated {
                content
            } else {
                lockScreen
            }
        }
        .onAppear { authenticate() }
        .onChange(of: model.pendingDeepLink) { _, pending in
            // A tapped push wants the unlock screen. Re-auth if we are still locked.
            if pending && !authenticated { authenticate() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-lock when the app leaves the foreground so a lost phone stays safe.
            if phase == .background { authenticated = false }
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 22) {
            Spacer()
            LogoTile(size: 64)
            Text("Nodlock is locked")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.txt)
            Text("Confirm it is you before unlocking your Mac.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.dim)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            if let errorText {
                Text(errorText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button {
                authenticate()
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 40)
            .disabled(authInFlight)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func authenticate() {
        guard !authInFlight else { return }
        authInFlight = true
        errorText = nil
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        let reason = "Unlock Nodlock to control your Mac's security prompt."

        // .deviceOwnerAuthentication = biometrics with automatic passcode fallback.
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No biometrics and no passcode set: allow through rather than trap the user.
            authInFlight = false
            authenticated = true
            model.pendingDeepLink = false
            if model.isDemo {
                model.demoAuthNote = "Face ID is not available on this device, so the demo opened without it."
            }
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, err in
            DispatchQueue.main.async {
                authInFlight = false
                if success {
                    authenticated = true
                    model.pendingDeepLink = false
                } else if model.isDemo {
                    // Nothing behind the demo gate is real, so a failed or
                    // cancelled prompt must never dead-end the reviewer.
                    authenticated = true
                    model.pendingDeepLink = false
                    model.demoAuthNote = "Face ID was skipped for this demo. Nothing here reaches a real Mac."
                } else {
                    errorText = (err as? LAError)?.friendly ?? "Authentication failed. Try again."
                }
            }
        }
    }
}

private extension LAError {
    var friendly: String {
        switch code {
        case .userCancel, .appCancel, .systemCancel: return "Authentication cancelled."
        case .userFallback: return "Enter your passcode to continue."
        case .biometryNotEnrolled: return "Face ID is not set up on this device."
        case .biometryLockout: return "Face ID is locked. Use your passcode."
        default: return "Authentication failed. Try again."
        }
    }
}
