#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, staple, and zip the macOS app for release.
# Needs: SIGN_IDENTITY + BUNDLE_ID in ~/.config/op-guard/build.env, and a notarytool
# keychain profile (one-time): xcrun notarytool store-credentials nodlock-notary --key <p8> --key-id <id> --issuer <issuer>
set -euo pipefail
VERSION="${1:?usage: release-mac.sh <version>}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HOME/.config/op-guard/build.env" ] && . "$HOME/.config/op-guard/build.env"
APP_NAME="Nodlock"
cd "$MAC" && ./build-app.sh
APP=$(ls -d *.app | head -1)
OUT="/tmp/${APP_NAME}-release"; rm -rf "$OUT"; mkdir -p "$OUT"; cp -R "$APP" "$OUT/${APP_NAME}.app"
cd "$OUT"
codesign --force --deep --options runtime --timestamp -s "$SIGN_IDENTITY" "${APP_NAME}.app"
ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}-macOS-${VERSION}.zip"
xcrun notarytool submit "${APP_NAME}-macOS-${VERSION}.zip" --keychain-profile nodlock-notary --wait
xcrun stapler staple "${APP_NAME}.app"
rm -f "${APP_NAME}-macOS-${VERSION}.zip"; ditto -c -k --keepParent "${APP_NAME}.app" "${APP_NAME}-macOS-${VERSION}.zip"
spctl -a -vvv -t exec "${APP_NAME}.app"
echo "==> $OUT/${APP_NAME}-macOS-${VERSION}.zip (notarized + stapled)"
