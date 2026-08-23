# Nodlock App Store Submission Checklist

Work top to bottom. Each item is a gate; do not skip ahead. Paths are relative to the repo root.

## 0. Before you touch App Store Connect

- [ ] Rename is complete in the build: `CFBundleDisplayName` in `SentineliOS/Sentinel/Info.plist` reads `Nodlock`. Usage strings (`NSFaceIDUsageDescription`, `NSCameraUsageDescription`) say "Nodlock", not the old name. The App Store shows these strings in the permission dialogs; reviewers notice mismatches.
- [ ] Demo mode ("Try a demo" on the pairing screen) works on a clean install on a physical iPhone with no companion reachable. Walk the steps in `REVIEW_NOTES.md` end to end.
- [ ] Bundle ID decided. The repo uses `com.example.sentinel.ios` (yours goes in `SentineliOS/.env`) (set in `SentineliOS/project.yml` via `.env` + `./gen.sh`). You keep your own bundle ID; changing it later means a new App Store record, so settle it now. Anyone cloning the repo uses their own reverse-DNS ID.
- [ ] `DEVELOPMENT_TEAM` set to your team (your Team ID, in `SentineliOS/.env`) in `SentineliOS/.env`, regenerated with `./gen.sh` (or `xcodegen generate`).
- [ ] Privacy policy hosted at a public URL. Source: `appstore/PRIVACY_POLICY.md`. Replace the placeholder email first. Confirm the URL returns 200 from a phone on cellular.
- [ ] Support URL live, with a contact method and a link to the Mac companion download.

## 1. Apple Developer account and agreements

- [ ] Paid Apps Agreement is not needed for a free app, but the current **Apple Developer Program License Agreement** must be accepted. App Store Connect > Agreements, Tax, and Banking. An unaccepted agreement blocks uploads silently.
- [ ] Account holder role is you (Individual account). Nothing to delegate.

## 2. Certificates, identifiers, capabilities

- [ ] App ID exists for your bundle ID under Certificates, Identifiers & Profiles > Identifiers, with **Push Notifications** enabled. Automatic signing in Xcode creates it on first device run; verify it anyway.
- [ ] APNs auth key (`.p8`, your Key ID) exists and is stored at `~/.config/op-guard/apns/AuthKey_<KEY_ID>.p8` on the Mac. One key covers sandbox and production.
- [ ] Xcode > target > Signing & Capabilities shows: Push Notifications, Background Modes with Remote notifications ticked, Automatic signing, your team.

## 3. Flip to production push

Development push tokens are rejected by the production APNs gateway. TestFlight and App Store builds are production.

- [ ] `SentineliOS/Sentinel/Sentinel.entitlements`: change `aps-environment` from `development` to `production`.
- [ ] On the Mac companion: set `OPG_APNS_ENV=production` in `~/.config/op-guard/env`, then restart the agent (`launchctl kickstart -k gui/$UID/<your label>`).
- [ ] Re-pair the phone after installing the TestFlight build. The device token changes when the APNs environment changes. Confirm a real push arrives before you submit.
- [ ] Keep a note to flip both back to `development` / `sandbox` for local debug builds, or you will chase a silent "no push" bug later.

## 4. Version and build numbers

- [ ] `MARKETING_VERSION` in `SentineliOS/project.yml` is `1.0` (ships as `CFBundleShortVersionString`). Fine for first release.
- [ ] `CURRENT_PROJECT_VERSION` is `1` (ships as `CFBundleVersion`). Every upload to App Store Connect needs a build number higher than any previous upload for the same version. Bump it before each archive, then `./gen.sh`.
- [ ] Version string in App Store Connect matches `CFBundleShortVersionString` exactly.

## 5. Export compliance

- [ ] Nodlock uses only HTTPS (URLSession to the Mac over the tunnel, and APNs is Apple's). Standard encryption from the OS is exempt under the App Store's export rules.
- [ ] Add to `SentineliOS/Sentinel/Info.plist`:

  ```xml
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  ```

  It is currently missing. Without it, App Store Connect asks the export compliance question on every upload. With it, the question is answered automatically and no annual self-classification report is required.

- [ ] Note for the honest answer: the app also allows plain `http://` to the Mac over a LAN (`NSAllowsArbitraryLoads` is `true` in Info.plist). That does not change the export answer; it still uses no proprietary or non-standard encryption.

## 6. App icon

- [ ] `SentineliOS/Sentinel/Assets.xcassets/AppIcon.appiconset/AppIcon.png` is 1024x1024, no alpha channel. Verified with `sips -g hasAlpha -g pixelWidth` (hasAlpha: no, pixelWidth: 1024). Nothing to do unless you redesign it for the new name.
- [ ] Icon does not contain the old project name or wordmark.

## 7. App Store Connect record

- [ ] My Apps > + > New App. Platform iOS, name `Nodlock`, primary language English (U.S.), your bundle ID, SKU `nodlock-ios-1` (any unique string), full access.
- [ ] Name availability: if "Nodlock" is taken, App Store Connect rejects it on this screen. Have a fallback ready (for example "Nodlock: Mac Unlock").
- [ ] Pricing and Availability: Free, all territories (or trim as you prefer).
- [ ] App Information: primary category Utilities, secondary Productivity. Content rights: does not contain third-party content. Age rating questionnaire: all None/No, result 4+ (see `LISTING.md`).
- [ ] App Privacy: answer **Data Not Collected**. Privacy policy URL filled. Publish the privacy answers (they have their own Publish button).
- [ ] Version page: paste subtitle, promotional text, description, keywords, support URL, marketing URL, copyright from `LISTING.md`.
- [ ] App Review Information: your contact details, Sign-in required: No, Notes: paste the block from `REVIEW_NOTES.md`. Attach a screen recording of the demo flow if you have one.
- [ ] Version Release: "Manually release this version" for the first submission, so you control the go-live moment.

## 8. Screenshots

Apple accepts one size per display class and scales down. As of 2026 the required classes for iPhone are:

- [ ] **6.9" display** (iPhone 16 Pro Max / 17 Pro Max class): 1320 x 2868 px portrait. Required. Also covers 6.7" devices.
- [ ] **6.5" display** (iPhone 11 Pro Max / XS Max class): 1242 x 2688 px portrait. Required unless your deployment target excludes those devices. Also covers 6.1" devices.
- [ ] iPad: only needed if the app is offered on iPad. `LSRequiresIPhoneOS` is true and the target family is iPhone-first; check `TARGETED_DEVICE_FAMILY` in `project.yml`. If iPad is included, add 13" iPad Pro shots (2064 x 2752 px) or remove iPad from the device family.
- [ ] Minimum 3 screenshots, maximum 10 per class. Ship 5 (see list below).
- [ ] Check App Store Connect's current size table before uploading; Apple updates it with each device generation.

### Screenshots to capture (all from demo mode on a real device, dark mode)

1. Pairing screen with the "Try a demo" button visible.
2. Demo banner plus the simulated 1Password prompt with its screenshot.
3. Face ID gate (the system Face ID overlay, or the locked state with the Face ID icon).
4. Unlock success: the "No prompt waiting" state right after tapping Unlock.
5. "Recent logins" card with a sample forwarded link.

Exact framing, sizes and captions are in `SCREENSHOT_PLAN.md`.

## 9. Archive and upload

- [ ] Xcode: select "Any iOS Device (arm64)" as destination.
- [ ] Product > Archive. Fix any signing error before going on.
- [ ] Organizer > Distribute App > App Store Connect > Upload. Keep "Upload your app's symbols" ticked, "Manage version and build number" unticked (you manage it in `project.yml`).
- [ ] Wait for the "build processed" email. Usually 5 to 30 minutes.
- [ ] If the email reports a missing `ITSAppUsesNonExemptEncryption` or missing usage description, fix, bump the build number, re-archive.

## 10. TestFlight first

- [ ] TestFlight tab > the processed build > add to an Internal Testing group (your own Apple ID). No review needed for internal testers.
- [ ] Install from the TestFlight app on your phone. Confirm: display name is Nodlock, demo mode works, real pairing with your Mac works, a real push arrives (production APNs), Face ID gate re-locks on background.
- [ ] Only after all of that: go back to the version page and select this build.

## 11. Submit

- [ ] Version page > Add Build > pick the TestFlight-verified build.
- [ ] Export compliance: if asked, answer No to "uses non-exempt encryption" (or it is already answered by the Info.plist key).
- [ ] Advertising identifier: No, the app does not use IDFA.
- [ ] Submit for Review. Typical first review is 24 to 48 hours.

## 12. If rejected

Read the rejection carefully; most are fixable with a reply, not a new build.

| Rejection | Likely cause | Response |
| --- | --- | --- |
| 2.1 "We were unable to review the app because it requires a companion." | Reviewer missed demo mode. | Reply in Resolution Center with the numbered demo steps and a screen recording. Do not resubmit a build unless demo mode is actually broken. |
| 2.1 Crash or bug on launch | Something in the build. | Reproduce on a clean device with the exact archived build, fix, bump build number, resubmit. |
| 2.3.3 Screenshots do not reflect the app | Captions or framing look like mock-ups. | Re-capture plain device shots, keep overlays small and factual. |
| 4.2 Minimum functionality | Reviewer saw only the pairing screen. | Same as 2.1: demo steps plus video. Point out push, biometrics, live screenshot, input relay, login inbox. |
| 5.1.1 Missing privacy policy or mismatch | URL dead, or label says Collected. | Fix the URL; confirm App Privacy is Data Not Collected and published. |
| 5.1.1(v) Demo account required | Reviewer assumed there is a login. | Reply: no account exists, sign-in required is No, demo mode covers testing. |
| 2.5.4 Background mode misuse | Reviewer questions remote-notification. | Reply: used only to receive prompt alerts; no other background work. |
| Guideline 2.3.1 hidden features | Reviewer thinks demo mode is a hidden switch. | Reply: it is a visible button on the first screen, documented in the notes, and meant for evaluation. |
| Metadata rejection (name, keywords) | Keyword stuffing or trademark. | Remove "1Password" from keywords if flagged as a trademark, keep it in the description as a compatibility statement. |

General rule: reply first, rebuild second. Replies in Resolution Center keep your place in the queue; a new build starts over.

## 13. After approval

- [ ] Release manually from the version page.
- [ ] Tag the repo commit that produced the archive.
- [ ] Switch local debug builds back to `development` / `sandbox` if you flipped the shared files rather than using a separate configuration.
- [ ] Update the support page with the App Store link.
