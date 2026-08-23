import SwiftUI

// The screenshot pane. Shows the live dialog image with tap-to-click (reporting
// fractional coordinates), or an empty state when no prompt is on screen.
struct DialogShot: View {
    var image: UIImage?
    var hasDialog: Bool
    // fx, fy are 0..1 fractions of the image, matching POST /click.
    var onTap: (Double, Double) -> Void

    @State private var imageSize: CGSize = .zero
    @State private var ping: Ping?

    var body: some View {
        ZStack {
            if let image, hasDialog {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { imageSize = geo.size }
                                .onChange(of: geo.size) { _, new in imageSize = new }
                        }
                    )
                    .gesture(
                        SpatialTapGesture(coordinateSpace: .local)
                            .onEnded { value in handleTap(value.location) }
                    )
                    .overlay { pingOverlay }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.dim)
                    Text("No dialog on screen")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.dim)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            }
        }
        .background(Color(hex: 0x05070C))
        .clipShape(RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.ctrlRadius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    private func handleTap(_ location: CGPoint) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let fx = max(0, min(1, location.x / imageSize.width))
        let fy = max(0, min(1, location.y / imageSize.height))
        ping = Ping(x: location.x, y: location.y)
        onTap(Double(fx), Double(fy))
    }

    @ViewBuilder private var pingOverlay: some View {
        if let ping {
            Circle()
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: 44, height: 44)
                .position(x: ping.x, y: ping.y)
                .modifier(PingAnimation())
                .id(ping.id)
                .allowsHitTesting(false)
        }
    }
}

private struct Ping: Equatable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
}

// One-shot expand + fade, mirroring the panel's @keyframes ping.
private struct PingAnimation: ViewModifier {
    @State private var animate = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(animate ? 1.2 : 0.3)
            .opacity(animate ? 0 : 0.9)
            .onAppear {
                withAnimation(.easeOut(duration: 0.6)) { animate = true }
            }
    }
}
