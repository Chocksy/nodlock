import SwiftUI

// The native equivalent of the web panel: live status, dialog screenshot,
// tap-to-click, password autofill, and the Return/Esc/Tab keys.
struct UnlockView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var vm: UnlockViewModel

    @State private var password = ""
    @State private var returnAfter = true
    @State private var toast: String?
    @State private var showUnpairAlert = false
    @State private var busy = false
    @FocusState private var pwFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // A placeholder client is replaced in onAppear once the environment pairing is known.
        _vm = StateObject(wrappedValue: UnlockViewModel())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                demoBanner
                header
                card
                loginsCard
                Text("Private and encrypted. Nothing is stored.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            if let client = model.client { vm.attach(client) }
            vm.start()
        }
        .onDisappear { vm.stop() }
        // Pause the 2s poll while backgrounded (phone locked) so it doesn't spam
        // failed requests; resume on foreground.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { vm.start() } else { vm.stop() }
        }
        .alert("Unpair this Mac?", isPresented: $showUnpairAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("Nodlock will forget the host and token, and ask the Mac to stop sending push notifications.")
        }
    }

    // MARK: - Header

    // Demo mode is loud enough to never be mistaken for a real Mac, quiet enough
    // that the rest of the screen still shows the product as it ships.
    @ViewBuilder private var demoBanner: some View {
        if model.isDemo {
            VStack(alignment: .leading, spacing: 6) {
                Label("Demo mode \u{2014} simulating a Mac. Unpair to connect a real one.",
                      systemImage: "wand.and.stars")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = model.demoAuthNote {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous)
                    .strokeBorder(Theme.warn.opacity(0.45), lineWidth: 1)
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoTile()
            Text("Nodlock")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.txt)
            Spacer()
            StatusChip(label: chipLabel, tone: chipTone)
            Menu {
                Button(role: .destructive) { showUnpairAlert = true } label: {
                    Label("Unpair \(model.pairing?.displayHost ?? "Mac")", systemImage: "xmark.shield")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.top, 6)
    }

    private var chipLabel: String {
        guard vm.online else { return "offline" }
        if vm.status?.hasDialog == true { return "prompt active" }
        if let up = vm.status?.uptime_s { return "idle · \(Int(up / 60))m up" }
        return "idle"
    }

    private var chipTone: ChipTone {
        if !vm.online { return .danger }
        return vm.status?.hasDialog == true ? .ok : .dim
    }

    // MARK: - Main card

    private var card: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(ownerText)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 2)

                DialogShot(image: vm.shot, hasDialog: vm.status?.hasDialog == true) { fx, fy in
                    send { try await vm.client?.click(fx: fx, fy: fy) }
                    toastNow("Clicked")
                }

                // Autofill target: .password lets iOS / 1Password offer the saved password.
                HStack(spacing: 8) {
                    SecureField("Password (Face ID / 1Password)", text: $password)
                        .textContentType(.password)
                        .submitLabel(.go)
                        .focused($pwFocused)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.txt)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous)
                                .strokeBorder(pwFocused ? Theme.accent : Theme.line, lineWidth: pwFocused ? 2 : 1)
                        )
                        .onSubmit(unlock)

                    Button(action: unlock) {
                        HStack(spacing: 6) {
                            if busy { ProgressView().tint(.white).scaleEffect(0.8) }
                            Text(busy ? "Sending" : "Unlock")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .fixedSize()
                    .disabled(busy)
                }

                Toggle(isOn: $returnAfter) {
                    Text("Press Return after typing")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                .tint(Theme.accent)

                HStack(spacing: 8) {
                    keyButton("Return", key: "return")
                    keyButton("Esc", key: "esc")
                    keyButton("Tab", key: "tab")
                }
            }
        }
    }

    @ViewBuilder private var loginsCard: some View {
        if !vm.logins.isEmpty {
            GlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent logins")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.txt)
                        Spacer()
                        Button {
                            Task {
                                try? await vm.client?.clearLogins()
                                await vm.refresh()
                            }
                            toastNow("Cleared")
                        } label: {
                            Text("Clear")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    ForEach(vm.logins) { login in
                        loginRow(login)
                    }
                }
            }
        }
    }

    private func loginRow(_ login: LoginRequest) -> some View {
        Button {
            if let url = URL(string: login.url) { UIApplication.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(loginHost(login.url))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.txt)
                        .lineLimit(1)
                    Text(relativeTime(login.ts))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                }
                Spacer()
                Text("Open")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loginHost(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? urlString
    }

    private func relativeTime(_ ts: Int) -> String {
        let secs = max(Int(Date().timeIntervalSince1970) - ts, 0)
        if secs < 60 { return "\(secs)s ago" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs)h ago" }
        return "\(hrs / 24)d ago"
    }

    private var ownerText: String {
        guard vm.online else { return "Can't reach your Mac right now." }
        if let owner = vm.status?.dialog, !owner.isEmpty { return "\(owner) is asking" }
        return "No security prompt right now."
    }

    private func keyButton(_ title: String, key: String) -> some View {
        Button(title) {
            send { try await vm.client?.key(key) }
            toastNow(title)
        }
        .buttonStyle(GhostButtonStyle())
    }

    // MARK: - Actions

    private func unlock() {
        guard !busy else { return }                      // ignore re-taps while in flight
        let pw = password
        guard !pw.isEmpty else { toastNow("Enter a password"); return }
        busy = true
        pwFocused = false
        let enter = returnAfter
        Task {
            do {
                try await vm.client?.type(text: pw, enter: enter)
                password = ""
                toastNow("Typed on Mac ✓")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                toastNow("Failed to reach Mac")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            busy = false
        }
    }

    private func send(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() }
            catch {
                toastNow("Failed to reach Mac")
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: - Toast

    private func toastNow(_ text: String) {
        withAnimation(.spring(duration: 0.25)) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.txt)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(Color(hex: 0x141820).opacity(0.95), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
