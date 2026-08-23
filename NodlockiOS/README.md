# Nodlock (iOS)

Native SwiftUI phone client for the Nodlock Mac menu-bar app. It mirrors the
tailnet-only web panel: see the live macOS security prompt, tap-to-click it, and
type the password with Face ID and 1Password autofill.

No third-party dependencies. Pure SwiftUI + AVFoundation (QR) + LocalAuthentication
(Face ID) + Security (Keychain) + UserNotifications (APNs).

## What it does

1. **Pairing** — Scan the QR the Mac menu-bar app shows (it encodes
   `http://<host>:8377?k=<token>`), or paste that link. Host + token are stored in
   the iOS **Keychain**, never UserDefaults. Unpair from the `…` menu on the unlock
   screen.
2. **Push** — Registers for APNs, then `POST <host>/register?k=<token>` with
   `token=<hexDeviceToken>&platform=ios`. Re-registers when the APNs token changes.
   On unpair it best-effort `POST <host>/unregister`.
3. **Face ID gate** — The unlock screen is hidden behind LocalAuthentication
   (Face ID / Touch ID, passcode fallback). The app re-locks when backgrounded.
4. **Unlock flow** (same endpoints as the web panel):
   - Polls `GET /status?k=<token>` every 2s. Shows "no prompt" when `dialog` is null.
   - Shows the live `GET /shot.png?k=<token>`, refreshed each poll.
   - `SecureField` with `.textContentType(.password)` so iOS / 1Password autofill
     offers the saved password. **Unlock** does `POST /type?k=<token>` with
     `text=<pw>&enter=on`.
   - Return / Esc / Tab → `POST /key?k=<token>` with `k=return|esc|tab`.
   - Tap on the screenshot → `POST /click?k=<token>` with `fx=<0..1>&fy=<0..1>`.
   - Tapping a push deep-links straight into the unlock screen (after Face ID).

## Demo mode

The pairing screen has a quiet **Try a demo** link. It stores a pairing for
`demo://local` (token `demo`) in the Keychain, and every panel call is answered
by `DemoClient` on-device: no network, no push, no Mac. The script goes idle →
fake "1Password" prompt after ~5s → typing anything clears it after ~1s and
records a login. Esc dismisses it. The unlock screen is the real one, with an
amber "demo mode" banner on top. Unpair wipes the demo state.

This exists so App Review can walk the whole flow without the Mac app.

## Project layout

```
NodlockiOS/
  project.yml                     # XcodeGen spec (regenerates the .xcodeproj)
  Nodlock.xcodeproj               # generated; safe to delete + regenerate
  Nodlock/
    NodlockApp.swift              # @main App, AppModel, AppDelegate (APNs + taps)
    RootView.swift                # pair-vs-unlock switch + BiometricGate (Face ID)
    Theme.swift                   # dark-glass palette, cards, buttons, status chip
    KeychainStore.swift           # Pairing (host+token) in the Keychain
    NodlockClient.swift           # async URLSession calls, all carry ?k=<token>
    Info.plist                    # usage strings, background modes, ATS
    Nodlock.entitlements          # aps-environment = development
    Assets.xcassets               # AppIcon slot + AccentColor
    Pairing/
      PairingView.swift           # scan / paste UI
      QRScannerView.swift         # AVFoundation QR scanner
    Unlock/
      UnlockView.swift            # the panel, native
      UnlockViewModel.swift       # 2s poll of /status + /shot.png
      DialogShot.swift            # screenshot + tap-to-click + ping
```

Regenerate the project after changing `project.yml`:

```
brew install xcodegen   # if needed
xcodegen generate
```

## Build (simulator, no signing)

```
xcodebuild -scheme Nodlock -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

## Before running on a real device — you must set these in Xcode

Push and Face ID need a signed build on hardware. In Xcode:

1. **Signing** — Target *Nodlock* → *Signing & Capabilities* → pick your **Team**.
   The bundle ID defaults to `com.example.sentinel.ios`. Set yours (and your Team ID) in `NodlockiOS/.env` (copy `.env.example`), then run `./gen.sh`.
2. **Push Notifications capability** — add the *Push Notifications* capability
   (this pairs with the `aps-environment` entitlement already in
   `Nodlock.entitlements`). For a production build switch that value to `production`.
3. **Background Modes → Remote notifications** — add the *Background Modes*
   capability and check **Remote notifications**. (`UIBackgroundModes =
   remote-notification` is already in `Info.plist`; Xcode just needs the capability
   toggled so provisioning matches.)
4. Make sure your Apple Developer account has an **APNs key/certificate** and that
   the Mac server pushes to it. The Mac stores the device token this app registers.

The simulator has no APNs; `didFailToRegisterForRemoteNotifications` there is
expected and handled quietly. Everything else (pairing, Face ID with a simulated
enrollment, status polling, typing) works in the simulator.

## Networking note

The Mac panel is plain HTTP on the tailnet, so `Info.plist` sets
`NSAppTransportSecurity → NSAllowsArbitraryLoads = true`. The device must be on the
same tailnet (Tailscale) to reach `http://<host>:8377`.
