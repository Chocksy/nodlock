# Nodlock: Notes for App Review

Paste the block below into App Store Connect > App Review Information > Notes. The sections after it are background for you, not for the reviewer.

---

## Notes for Review (paste this)

```
Thank you for reviewing Nodlock.

WHAT IT IS
Nodlock is the iPhone half of a two-part tool. The other half is a free, open-source menu-bar app the user installs on their own Mac. When the Mac shows a security prompt (1Password unlock, macOS password dialog, keychain prompt), the Mac companion sends a push notification to the phone. The user opens Nodlock, passes Face ID, sees a screenshot of the prompt, types the password, and taps Unlock. The password is sent to the user's own Mac and typed into the dialog. The companion can also forward CLI login links (OAuth, SSO, device codes) to the phone.

NO LOGIN REQUIRED
There is no account, no sign-up, and no server run by us. The app talks only to the user's own Mac.

HOW TO TEST WITHOUT A MAC: DEMO MODE
You do not need the Mac companion to review the full flow. The app ships with a demo mode that simulates a paired Mac.

1. Launch Nodlock. You land on the pairing screen.
2. Tap "Try a demo" at the bottom of the pairing screen. The app pairs with a simulated Mac and shows a "Demo" banner.
3. Allow notifications if asked (optional; the demo works either way).
4. Wait about 5 seconds. A simulated 1Password unlock prompt appears, with a screenshot of the dialog, exactly as it would from a real Mac.
5. Authenticate with Face ID, Touch ID, or the device passcode. (On a device without biometrics enrolled, the passcode prompt appears instead.)
6. Type any text into the password field and tap "Unlock". The simulated prompt clears and the screen returns to "No prompt waiting", which is what happens on a real Mac once the dialog is dismissed.
7. Scroll down to see the "Recent logins" card. In demo mode it holds a sample forwarded login link to show how CLI sign-in forwarding looks.
8. To leave demo mode, open the "..." menu on the unlock screen and choose Unpair. You return to the pairing screen.

Nothing in demo mode leaves the device. No network calls are made.

GUIDELINE NOTES

2.1 App Completeness: the app is fully functional. The demo mode exists so you can exercise every screen without installing the macOS companion. With a real Mac, the flow is identical; the screenshot and prompt come from the Mac instead of the simulator.

4.2 Minimum Functionality: Nodlock is a companion app with real, ongoing utility: it receives push notifications, gates access with biometrics, renders a live screenshot stream, relays typed input and taps, and keeps a list of forwarded login links. It is a native SwiftUI app, not a web wrapper.

5.1.1 Data Collection and Storage: we collect nothing. There is no developer server. The pairing host and token are stored in the iOS Keychain on the user's phone. Passwords typed by the user are sent once to the user's own Mac over a channel the user controls (Cloudflare Tunnel with Cloudflare Access, VPN, or local network), typed into the dialog, and never stored or logged on either side. App Privacy is declared as "Data Not Collected". A privacy policy is linked.

2.5.4 Background Modes: the only background mode is remote-notification, used to receive the "a prompt is waiting" push. The app does no background processing beyond handling that notification.

Credential handling: every password entry is user-initiated. The user sees a screenshot of the exact prompt, authenticates with Face ID, and types the password themselves (iOS and 1Password autofill are supported through the standard SecureField). Nodlock never reads, stores, or syncs credentials. It relays what the user typed to the user's own machine, once.

Push notification content: prompt notifications contain a title and the name of the app that raised the prompt. Login notifications contain the title "Login needed", the Mac's hostname, and the login URL. No screenshot or password is ever sent through APNs.

Camera: used only to scan the pairing QR code. Face ID: used only to gate the unlock screen.

If anything is unclear, reply through Resolution Center and we will answer quickly.
```

---

## Background for the submitter (not for the reviewer)

### Why the demo mode matters

Guideline 2.1 rejections for companion apps are common: the reviewer cannot install the Mac half, so they see a pairing screen and nothing else. The demo mode is the answer. Make sure it is present and working in the exact build you upload; test it on a clean device install before submitting.

Capture a short screen recording of the demo flow as well. If the reviewer still cannot find "Try a demo", you can attach the video in Resolution Center instead of arguing.

### Pre-empted concerns, mapped to guidelines

| Guideline | Likely concern | Our answer |
| --- | --- | --- |
| 2.1 App Completeness | "We could not test the app; it requires a Mac." | Demo mode. Steps above. |
| 2.3 Accurate Metadata | Screenshots must show the real app. | All screenshots come from the demo mode on a real device. No mock-ups. |
| 2.5.4 Background Modes | Apps must use background modes for their stated purpose. | Only remote-notification, only for prompt alerts. |
| 4.2 Minimum Functionality | "This is just a remote control / thin client." | Native app with biometrics, push, live screenshot, input relay, and a login link inbox. Not a web view. |
| 5.1.1 Data Collection | Passwords are sensitive. | User-initiated, transit-only, never stored. No developer server. Data Not Collected. |
| 5.1.1(v) Account Sign-In | Apps that require login must offer a demo account. | No login exists. Tick "Sign-in required: No". |
| 5.1.2 Data Use and Sharing | Third-party sharing. | None. No SDKs. |
| 4.0 Design | Must be useful on iPhone. | Portrait-only, native SwiftUI, dark UI. |

### If the reviewer asks about the former name

The project was built under the working name "Sentinel". The bundle display name in the uploaded build must read "Nodlock". If the reviewer sees "Sentinel" anywhere, that is a build mistake on our side: rebuild with the display name fixed, do not argue.

### Things that would sink the review

- Demo mode missing or crashing on a device without the companion.
- Display name still showing the old project name.
- `aps-environment` still set to `development` (push will not work for the reviewer; demo mode still covers the flow, but fix it anyway).
- Privacy policy URL returning 404.
- Screenshots that show a different app name than the build.
