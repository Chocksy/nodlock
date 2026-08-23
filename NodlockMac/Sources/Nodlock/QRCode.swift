import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// Shared QR-image generation used by both the pairing window (QRWindow.swift)
// and the onboarding wizard (Onboarding.swift). Single source of truth so the
// two never drift.
enum QRCode {
    static func image(from string: String, side: CGFloat) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return NSImage(size: NSSize(width: side, height: side))
        }

        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }
}
