import SwiftUI

// Colors mirror the web panel's CSS variables (Panel.swift) so the phone client
// and the browser panel feel like one product.
enum Theme {
    static let bg      = Color(hex: 0x0B0D12)
    static let card    = Color.white.opacity(0.06)
    static let line    = Color.white.opacity(0.12)
    static let txt     = Color(hex: 0xEEF1F6)
    static let dim     = Color(hex: 0x9AA4B2)
    static let accent  = Color(hex: 0x4C8DFF)
    static let violet  = Color(hex: 0x7B5CFF)
    static let ok      = Color(hex: 0x2FD27A)
    static let warn    = Color(hex: 0xFFB020)
    static let danger  = Color(hex: 0xFF5C6C)

    static let cardRadius: CGFloat = 18
    static let ctrlRadius: CGFloat = 14

    // The two radial glows from the panel background, plus the base fill.
    static var background: some View {
        ZStack {
            bg
            RadialGradient(
                colors: [accent.opacity(0.18), .clear],
                center: UnitPoint(x: 0.2, y: -0.1),
                startRadius: 0, endRadius: 620
            )
            RadialGradient(
                colors: [ok.opacity(0.10), .clear],
                center: UnitPoint(x: 1.0, y: 0.0),
                startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }

    static let logoGradient = LinearGradient(
        colors: [accent, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let buttonGradient = LinearGradient(
        colors: [accent, Color(hex: 0x3B7BFF)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Reusable styled pieces

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.4))
            )
            .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 10)
    }
}

// Primary filled button (accent gradient), scales on press like the panel's .btn.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 18)
            .background(Theme.buttonGradient, in: RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// Ghost / secondary button matching .btn.ghost.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.txt)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// The status chip from the panel header: a glowing dot + label.
enum ChipTone {
    case ok, warn, danger, dim
    var color: Color {
        switch self {
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .danger: return Theme.danger
        case .dim: return Theme.dim
        }
    }
}

struct StatusChip: View {
    var label: String
    var tone: ChipTone
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tone.color)
                .frame(width: 8, height: 8)
                .shadow(color: tone.color, radius: 5)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.dim)
        }
    }
}

// The Nodlock logo tile from the panel header.
struct LogoTile: View {
    var size: CGFloat = 30
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.logoGradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: Theme.accent.opacity(0.4), radius: 9, x: 0, y: 6)
    }
}
