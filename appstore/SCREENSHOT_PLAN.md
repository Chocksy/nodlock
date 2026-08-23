# Nodlock Screenshot Plan

Five shots per display class, all captured from demo mode on a real iPhone. Same five shots at both sizes; only the device changes.

## Device sizes

| Class | Capture on | Pixel size (portrait) | Covers |
| --- | --- | --- | --- |
| 6.9" | iPhone 17 Pro Max or 16 Pro Max | 1320 x 2868 | 6.9" and 6.7" |
| 6.5" | iPhone 11 Pro Max, XS Max, or the 6.5" simulator | 1242 x 2688 | 6.5" and 6.1" |

If you have only one physical phone, capture the 6.9" set on it and the 6.5" set in the iOS Simulator (iPhone 11 Pro Max). Demo mode does not need APNs, so the simulator is fine. Face ID in the simulator: Features > Face ID > Enrolled, then Matching Face when prompted.

Check App Store Connect's current size table the day you upload; Apple changes it with new devices.

## Capture rules

- Dark mode (the app forces it, so this is automatic).
- Status bar: 9:41, full battery, full signal. Use Xcode's `xcrun simctl status_bar <device> override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3` in the simulator. On a real device, crop nothing; Apple accepts the real status bar.
- No personal data in frame. Demo mode uses simulated content, so this is automatic. Double check the "Recent logins" card shows only the sample link.
- Raw device captures first. Add caption overlays afterwards in a separate layer, so you can redo text without re-shooting.
- Keep overlays to one short line at the top, 10 to 12 percent of the height, app UI visible below. Apple rejects shots where the overlay hides the app.
- Export PNG, no alpha, sRGB.

## The five shots

### 1. Pairing screen

- **Screen:** first launch, pairing view. QR scanner button, paste-link field, and the "Try a demo" button all visible.
- **State:** fresh install, nothing paired. If you have paired already, Unpair from the unlock screen menu first.
- **Caption:** `Scan once. Your Mac and phone are paired.`
- **Why first:** it is what the reviewer sees on launch, and it shows the demo entry point.

### 2. Prompt waiting, with screenshot

- **Screen:** unlock view in demo mode, about 5 seconds after tapping "Try a demo". The "Demo" banner is visible at the top, the simulated 1Password unlock dialog is rendered as the screenshot, the password field is empty below it.
- **State:** already past Face ID. If the gate re-locked because you switched to the screenshot tool, authenticate again before shooting.
- **Caption:** `Your Mac asks. Your phone shows you exactly what.`
- **Why:** this is the product. Make it the hero shot if you reorder.

### 3. Face ID gate

- **Screen:** the locked state of the unlock view: the lock icon, the "Unlock with Face ID" button, no screenshot visible behind it.
- **State:** background the app and bring it back; the gate re-locks. Shoot before tapping the button. Do not try to capture the system Face ID overlay itself; it does not show in screenshots.
- **Caption:** `Face ID before a single keystroke leaves your phone.`

### 4. Unlock success

- **Screen:** unlock view right after typing text and tapping Unlock. The simulated prompt has cleared; the status chip reads the "no prompt" state.
- **State:** run the demo flow to the end. If you are too slow and the state resets, tap Unpair and start the demo again.
- **Caption:** `Typed into the dialog. Never stored, never logged.`

### 5. Recent logins

- **Screen:** unlock view scrolled so the "Recent logins" card fills the middle of the frame, with the sample forwarded link visible.
- **State:** demo mode, any time after pairing.
- **Caption:** `CLI sign-ins land on your phone as a tap.`

## Optional sixth shot (skip if the first five are clean)

- **Screen:** the Mac side: menu-bar popover with the pairing QR. Capture on the Mac, then compose it into a phone-size frame with a caption.
- **Caption:** `Free, open-source companion for macOS 14+.`
- **Note:** Apple allows a non-device image if it is clearly explanatory. Keep it last so a reviewer does not mistake it for the iOS app.

## Overlay style

- Font: SF Pro Display Semibold, white, on the app's dark background. No drop shadow.
- Size: about 64 px tall at 6.9" (scale proportionally for 6.5").
- Position: centered, top safe area plus 40 px.
- No device bezel frames. Flat, full-bleed captures look cleaner in the dark theme and avoid the "which device is this" question.
- Same caption text at both sizes.

## File naming

```
appstore/screenshots/6.9/01-pairing.png
appstore/screenshots/6.9/02-prompt.png
appstore/screenshots/6.9/03-faceid.png
appstore/screenshots/6.9/04-unlocked.png
appstore/screenshots/6.9/05-logins.png
appstore/screenshots/6.5/01-pairing.png
...
```

Upload in numeric order; App Store Connect keeps the order you drag them in.

## Verification before upload

- [ ] `sips -g pixelWidth -g pixelHeight -g hasAlpha <file>` matches the table above and reports `hasAlpha: no`.
- [ ] No "Sentinel" text visible in any frame (old project name). Search the captured UI by eye: banner, navigation title, menu.
- [ ] Captions contain no em dashes and no claims the app cannot back up.
- [ ] The same five shots exist at both sizes.
