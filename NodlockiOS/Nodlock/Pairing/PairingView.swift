import SwiftUI

// First-run screen: scan the QR from the Mac menu bar, or paste the panel URL.
struct PairingView: View {
    @EnvironmentObject private var model: AppModel

    @State private var showScanner = false
    @State private var manual = ""
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Pair with your Mac")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.txt)
                        Text("Open the Nodlock menu-bar app on your Mac and scan the QR code it shows. Everything stays on your own network.")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.dim)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            error = nil
                            showScanner = true
                        } label: {
                            Label("Scan QR code", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Or paste the panel link", systemImage: "link")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Theme.dim)
                        TextField("http://mac-mini.local:8377?k=…", text: $manual)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundStyle(Theme.txt)
                            .padding(14)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous)
                                    .strokeBorder(Theme.line, lineWidth: 1)
                            )
                        Button("Pair") { pair(manual) }
                            .buttonStyle(GhostButtonStyle())
                            .disabled(manual.isEmpty)
                    }
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 4)
                }

                demoLink

                Text("Your network only. Nothing is stored on a server.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showScanner) {
            ScannerSheet { code in
                showScanner = false
                pair(code)
            } onError: { message in
                showScanner = false
                error = message
            }
        }
    }

    // Tertiary, deliberately quiet: it exists so App Review (and anyone without
    // the Mac app yet) can see the whole flow against the on-device fake.
    private var demoLink: some View {
        VStack(spacing: 4) {
            Button {
                error = nil
                model.startDemo()
            } label: {
                Text("Try a demo")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.dim)
                    .underline()
            }
            .buttonStyle(.plain)
            Text("No Mac needed. Walks the unlock flow with a simulated one.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LogoTile()
            Text("Nodlock")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.txt)
            Spacer()
            StatusChip(label: "not paired", tone: .danger)
        }
        .padding(.top, 6)
    }

    private func pair(_ raw: String) {
        if model.pair(from: raw) {
            error = nil
        } else {
            error = "That does not look like a Nodlock panel link. It should contain ?k=<token>."
        }
    }
}

// Full-screen scanner presented as a sheet with a framed reticle.
private struct ScannerSheet: View {
    var onFound: (String) -> Void
    var onError: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRScannerView(onFound: onFound, onError: onError)
                .ignoresSafeArea()

            VStack {
                Spacer()
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .frame(width: 240, height: 240)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 16)
                Text("Point at the QR code on your Mac")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.top, 20)
                Spacer()
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
    }
}
