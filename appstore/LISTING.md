# Nodlock App Store Listing

Copy-paste source for every text field in App Store Connect. Character limits are noted where Apple enforces them.

## Name (30 chars max)

```
Nodlock
```

## Subtitle (30 chars max)

```
Approve Mac prompts on iPhone
```

(29 characters. Alternatives: "Unlock your Mac from your phone" is 31, too long. "Mac security prompts, on iPhone" is 31, too long.)

## Promotional text (170 chars max, editable without a new build)

```
Your Mac asked for a password. You are not there. Nodlock pushes the prompt to your phone, you approve it with Face ID, and the Mac types it in. Try the built-in demo.
```

## Description (4000 chars max)

```
Nodlock lets you answer security prompts on your Mac from your iPhone.

When your Mac shows a 1Password unlock, a macOS password dialog, or a keychain prompt, the Nodlock companion on the Mac takes a screenshot and sends a push to your phone. Open the notification, pass Face ID, look at the prompt, type the password (1Password and iCloud Keychain autofill work), and tap Unlock. The Mac types it into the dialog. Done, from the sofa or from another country.

REQUIRES A MAC COMPANION
Nodlock is the phone half of a two-part tool. The other half is a free, open-source menu-bar app for macOS 14 or later that you install on your own Mac. Without it, the iOS app has nothing to talk to. A built-in demo mode lets you walk through the whole flow before you install anything on the Mac: tap "Try a demo" on the pairing screen.

WHAT IT DOES
• Detects 1Password, SecurityAgent and keychain prompts on your Mac
• Pushes a notification to your phone the moment a prompt appears
• Shows you a live screenshot so you know exactly what you are approving
• Types the password into the dialog, with Return, Escape and Tab on hand
• Tap anywhere on the screenshot to click that spot on the Mac
• Forwards CLI login links (device codes, OAuth, SSO) to your phone so you can finish sign-ins there
• Keeps a "Recent logins" list of forwarded links

BUILT FOR PEOPLE WHO RUN THINGS ON THEIR MAC
Remote builds, long-running agents, headless Mac minis, a desktop that keeps asking for a password while you are away from the desk. Nodlock turns a blocked job into a ten-second tap on your phone.

PRIVATE BY DESIGN
• No account. No sign-up. Nothing to log into.
• No server run by us. Your phone talks only to your Mac.
• Push notifications carry a title and the name of the prompting app. Never a screenshot, never a password.
• Passwords travel once, get typed once, and are never stored or logged on either device.
• Pairing credentials live in the iOS Keychain.
• Face ID gates the unlock screen and re-locks when you switch apps.
• No analytics, no tracking, no third-party SDKs.

HOW THE CONNECTION WORKS
The Mac companion listens only on localhost. You decide how your phone reaches it: a Cloudflare Tunnel protected by Cloudflare Access for access from anywhere, a VPN, or your home network. The Mac shows a QR code; you scan it once and you are paired.

SETUP IN BRIEF
1. Install the companion on your Mac (link on the support page) and grant it Screen Recording and Accessibility.
2. Open Nodlock on your iPhone and scan the pairing QR from the Mac's menu bar.
3. Wait for the next prompt. That is it.

Nodlock is free and open source. The companion's source is published so you can read exactly what runs on your Mac.
```

## Keywords (100 chars max, comma-separated, no spaces)

```
mac,unlock,1password,password,prompt,remote,approve,face id,keychain,oauth,sso,companion,menu bar
```

(98 characters. Do not repeat words already in the name or subtitle; Apple indexes those for free.)

## What's New (first release)

```
First release. Pair with the Mac companion, approve prompts with Face ID, forward CLI login links to your phone. Includes a demo mode so you can try the flow before installing the companion.
```

## Category

- Primary: Utilities
- Secondary: Productivity

## Age rating

Answer "None" or "No" to every question in the questionnaire. Result: 4+.

| Question | Answer |
| --- | --- |
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic realistic violence | None |
| Profanity or crude humor | None |
| Mature or suggestive themes | None |
| Horror or fear themes | None |
| Medical or treatment information | None |
| Alcohol, tobacco, or drug use or references | None |
| Simulated gambling | None |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Contests | None |
| Gambling | No |
| Unrestricted web access | No |
| Made for Kids | No |

## URLs

- Support URL: https://example.com/nodlock/support (replace; must resolve to a page with contact info and the companion download)
- Marketing URL (optional): https://example.com/nodlock (replace or leave blank)
- Privacy Policy URL: https://example.com/nodlock/privacy (host `appstore/PRIVACY_POLICY.md` here)

## Copyright

```
2026 Razvan Ciocanel
```

## Pricing

Free. No in-app purchases.

## App Review contact

Fill in your name, phone number and email in the App Review Information section. Demo account fields: leave blank and tick "Sign-in required: No". The review notes in `REVIEW_NOTES.md` explain the demo mode.

## Former name

The project was developed under the working name "Sentinel". The shipping name is Nodlock. Do not use the old name anywhere in the listing; Apple may flag a mismatch between the listing and the bundle display name, so make sure `CFBundleDisplayName` reads "Nodlock" in the build you upload.
