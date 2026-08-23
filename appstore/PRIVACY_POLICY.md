# Nodlock Privacy Policy

Effective date: 2026-08-21

Nodlock is an iOS app that lets you approve security prompts on your own Mac from your phone. This policy explains what the app does with data, in plain terms. The short version: the developer collects nothing. Your data moves between your phone and your Mac, and nowhere else.

## What Nodlock does

Nodlock pairs with a companion app running on your Mac. When the Mac shows a security prompt (a 1Password unlock, a macOS password dialog, a keychain prompt), the Mac sends a push notification to your phone. You open Nodlock, pass Face ID, see a screenshot of the prompt, type the password, and the Mac types it into the dialog.

The Mac companion can also forward login links (device-code, OAuth and SSO URLs opened by command-line tools) to your phone so you can finish a sign-in there.

Nodlock has no accounts, no sign-up, no server run by the developer, no analytics, and no third-party SDKs.

## Data the developer collects

None.

The developer does not operate any server that Nodlock talks to. The developer receives no usage data, no crash reports through the app, no identifiers, and no content. There is nothing to sell, share, or lose.

## Data that moves between your phone and your Mac

All of this stays on devices and networks you control. None of it reaches the developer.

| Data | Direction | Why | Stored? |
| --- | --- | --- | --- |
| Pairing host and access token | Mac to phone (QR code or pasted link) | Tells the app where your Mac is and proves the app is allowed to talk to it | Yes, in the iOS Keychain on your phone. Removed when you unpair. |
| Push device token | Phone to Mac | Lets your Mac address push notifications to your phone | Yes, on your Mac only. Removed when you unpair. |
| Screenshot of the security prompt | Mac to phone | So you can see what you are approving | Held in memory while the unlock screen is open. Not written to disk on the phone. |
| Password and keystrokes | Phone to Mac | Typed into the Mac dialog on your behalf | No. Sent once, typed once, not logged, not cached, not written to disk on either device. |
| Taps on the screenshot | Phone to Mac | Clicks the dialog where you tap | No. |
| Prompt status (is a dialog open, which app owns it) | Mac to phone | Drives the unlock screen | No. |
| Recent login URLs | Mac to phone | The "Recent logins" card | Kept in memory on your Mac until you clear them or restart the companion. |

### Transport

Traffic between the phone and the Mac goes over a channel you set up: a Cloudflare Tunnel protected by Cloudflare Access, a VPN, or your own local network. The Mac companion listens only on its loopback interface; it does not expose a port to the internet on its own. Every request carries the pairing token. When you use Cloudflare Access, requests also carry your Access service token headers.

The developer has no access to that channel. If you use Cloudflare, Cloudflare's own privacy policy governs their handling of tunnel traffic.

## Push notifications (APNs)

Push notifications travel through Apple Push Notification service. Payloads are kept small on purpose.

For a security prompt, the payload contains:

- a title (for example "1Password wants to unlock")
- the name of the app that owns the prompt

No screenshot, no password, and no keystroke ever goes through APNs.

For a forwarded login link, the payload contains:

- the title "Login needed"
- the short hostname of your Mac
- the login URL itself, so the phone can open it when you tap

Apple's handling of push traffic is covered by Apple's privacy policy.

## Permissions the app asks for

| Permission | Used for | What happens if you decline |
| --- | --- | --- |
| Face ID (or Touch ID, with passcode fallback) | Gating the unlock screen so nobody else can type into your Mac from your phone | You cannot open the unlock screen. |
| Camera | Scanning the pairing QR code shown by the Mac companion | You can paste the pairing link instead. |
| Notifications | Telling you a prompt is waiting on your Mac | The app still works when you open it by hand, but you get no alerts. |

The camera is used only while the scanner view is open. No photos or video are saved. Face ID is handled by iOS; Nodlock never sees your biometric data.

## Third parties

Nodlock contains no third-party SDKs, advertising frameworks, or analytics libraries. The only outside services involved are Apple (push delivery) and, if you choose to use it, Cloudflare (tunnel transport). Both are services you configure, not services the developer runs.

## Analytics and tracking

There are none. The app does not track you, does not fingerprint your device, and does not request the App Tracking Transparency permission because it has no reason to.

## Children

Nodlock is a utility for people who administer their own Mac. It is not directed at children under 13, and the developer does not knowingly collect data from anyone, children included.

## Data retention and deletion

The developer retains nothing, so there is nothing to delete on the developer's side. To remove the data Nodlock keeps on your devices:

- On the phone: unpair from the menu on the unlock screen, or delete the app. Both remove the pairing from the Keychain.
- On the Mac: unpairing sends an unregister request that removes your device token. Quitting the companion clears the in-memory login list.

## Security

- The unlock screen sits behind Face ID and re-locks when the app goes to the background.
- Pairing credentials live in the iOS Keychain, not in UserDefaults or files.
- Passwords are sent once and typed once. They are never logged or stored on either end.
- The pairing token is compared in constant time on the Mac.

No system is perfect. If you find a security issue, write to the address below.

## Changes to this policy

If the app's behaviour changes in a way that affects this policy, the policy will be updated here and the effective date bumped. Material changes will also be called out in the App Store release notes.

## Contact

Questions about this policy: privacy@example.com (replace with your real address before publishing)

## App Privacy (nutrition label) answers

These are the answers to give in App Store Connect under App Privacy.

**Do you or your third-party partners collect data from this app?**
No. Select "Data Not Collected".

Reasoning, in case a reviewer asks:

- Apple defines "collect" as transmitting data off the device in a way that lets the developer or a partner access it for longer than needed to service the request. Nodlock transmits data only to the user's own Mac. The developer never receives it.
- The pairing token and push token are stored on the user's devices only.
- Passwords transit to the user's Mac and are not retained anywhere.
- APNs delivery is Apple's infrastructure and does not count as developer collection.
- No analytics, no crash reporting SDK, no advertising identifiers, no third-party SDKs.

**Tracking:** No. The app does not track users across apps or websites.

**Privacy policy URL:** the URL where this document is hosted.
