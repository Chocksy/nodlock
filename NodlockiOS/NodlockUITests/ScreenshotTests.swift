import XCTest

// App Store screenshot capture. Drives the built-in demo mode so nothing here
// needs a real Mac, a real tailnet or a real 1Password.
//
// Label sources (no accessibilityIdentifiers exist in the app, so we match text):
//   "Try a demo"                        Pairing/PairingView.swift  demoLink
//   "Unlock with Face ID"               RootView.swift             lockScreen
//   "1Password is asking"               Unlock/UnlockView.swift    ownerText
//   "Password (Face ID / 1Password)"    Unlock/UnlockView.swift    SecureField
//   "Unlock"                            Unlock/UnlockView.swift    unlock button
//   "Recent logins"                     Unlock/UnlockView.swift    loginsCard
//
// setupSnapshot/snapshot are @MainActor in SnapshotHelper, so the whole flow
// lives in one @MainActor test rather than in setUp/tearDown overrides.
final class ScreenshotTests: XCTestCase {

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        continueAfterFailure = false

        let app = XCUIApplication()
        setupSnapshot(app, waitForAnimations: false)
        app.launch()

        // ---- 01 pairing -----------------------------------------------------
        // Tolerant: a snapshot retry reuses the simulator without erasing it, so
        // the app can already be paired in demo mode and skip straight to unlock.
        let demo = app.buttons["Try a demo"]
        if demo.waitForExistence(timeout: 30) {
            settle()
            snapshot("01-pairing")
            demo.tap()
        }

        // ---- 03 face id gate ------------------------------------------------
        // BiometricGate renders its lock screen, then calls authenticate() from
        // onAppear. Capture the gate before the system prompt covers it.
        let faceID = app.buttons["Unlock with Face ID"]
        if faceID.waitForExistence(timeout: 10) {
            // No long settle here: a match event resolves the gate within a few
            // seconds and the lock screen goes away with it.
            settle(0.4)
            snapshot("03-faceid")
        }

        // LAContext puts up a real Face ID sheet on this simulator and nothing
        // will ever satisfy it. Cancelling is enough: in demo mode the gate
        // treats a failed or cancelled evaluation as success (RootView.swift).
        dismissSystemAuthPrompt()

        // ---- 02 prompt ------------------------------------------------------
        // The secure field is always on UnlockView; the simulated 1Password
        // dialog only lands ~5s later, so wait for the owner text too.
        let field = app.secureTextFields["Password (Face ID / 1Password)"]
        XCTAssertTrue(field.waitForExistence(timeout: 45), "unlock screen never appeared")

        let asking = app.staticTexts["1Password is asking"]
        _ = asking.waitForExistence(timeout: 30)
        settle()
        snapshot("02-prompt")

        // ---- 04 unlocked ----------------------------------------------------
        if field.isHittable { field.tap() }
        field.typeText("correct-horse")

        // The Unlock button flips its label to "Sending" while in flight.
        let unlock = app.buttons["Unlock"]
        if unlock.waitForExistence(timeout: 10), unlock.isHittable {
            unlock.tap()
        }
        // DemoClient.type sleeps 1s, then the toast "Typed on Mac" shows ~1.6s.
        settle(1.6)
        snapshot("04-unlocked")

        // ---- 05 recent logins -----------------------------------------------
        // loginsCard is seeded from launch, but sits below the fold.
        let logins = app.staticTexts["Recent logins"]
        _ = logins.waitForExistence(timeout: 20)
        app.swipeUp()
        settle()
        snapshot("05-logins")
    }

    /// Taps whatever escape hatch the LocalAuthentication sheet offers. The sheet
    /// is owned by springboard, not the app, so it needs its own query.
    @MainActor
    private func dismissSystemAuthPrompt(timeout: TimeInterval = 20) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let labels = ["Cancel", "Use Passcode", "Enter Password", "OK", "Dismiss"]
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            for source in [springboard, XCUIApplication()] {
                for label in labels {
                    let button = source.buttons[label]
                    if button.exists && button.isHittable {
                        button.tap()
                        settle(0.5)
                        return
                    }
                }
            }
            // Nothing blocking us: the gate already let the demo through.
            if XCUIApplication().secureTextFields.firstMatch.exists { return }
            settle(0.5)
        }
    }

    // Pump the run loop instead of Thread.sleep. The test body is @MainActor, and
    // blocking the runner's main thread starves the XCTest IPC heartbeat, which
    // shows up as "Restarting after unexpected exit, crash, or test timeout".
    @MainActor
    private func settle(_ seconds: TimeInterval = 1.0) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
