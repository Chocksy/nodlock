import Foundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

// Capture ONLY the target window as PNG, keyed to Nodlock.app's own TCC identity.
// ScreenCaptureKit (preferred). Returns nil when Screen Recording is not granted
// or the window is gone.
func capturePNG(windowID: Int) -> Data? {
    let sem = DispatchSemaphore(value: 0)
    var result: Data?
    Task {
        result = await captureAsync(windowID: windowID)
        sem.signal()
    }
    sem.wait()
    return result
}

@available(macOS 14.0, *)
private func captureAsync(windowID: Int) async -> Data? {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let win = content.windows.first(where: { $0.windowID == CGWindowID(windowID) }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)))
        config.height = max(1, Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return pngData(from: cgImage)
    } catch {
        return nil
    }
}

private func pngData(from cgImage: CGImage) -> Data? {
    let rep = NSBitmapImageRep(cgImage: cgImage)
    return rep.representation(using: .png, properties: [:])
}
