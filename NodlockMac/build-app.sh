#!/usr/bin/env bash
# Build Nodlock.app: compile release, assemble the bundle, ad-hoc codesign.
set -euo pipefail

cd "$(dirname "$0")"

APP="Nodlock.app"
BUNDLE_ID="${BUNDLE_ID:-com.example.sentinel}"

echo "==> swift build -c release"
swift build -c release

BIN=".build/release/Nodlock"
if [[ ! -x "$BIN" ]]; then
  echo "build failed: $BIN not found" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nodlock"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Nodlock</string>
	<key>CFBundleDisplayName</key>
	<string>Nodlock</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleExecutable</key>
	<string>Nodlock</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSScreenCaptureUsageDescription</key>
	<string>Nodlock screenshots the security prompt so you can act on it from your phone.</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Signing identity. Default is ad-hoc ("-"), which needs no keychain and works
# on any Mac (open-source friendly). Set SIGN_IDENTITY to a real cert
# (e.g. "Developer ID Application: Name (TEAMID)") for a stable TCC identity
# and notarizable builds.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "==> ad-hoc codesign"
  codesign --force --deep -s - "$APP"
else
  echo "==> codesign with: $SIGN_IDENTITY (hardened runtime)"
  codesign --force --deep --options runtime --timestamp -s "$SIGN_IDENTITY" "$APP"
fi

echo "==> plutil -lint"
plutil -lint "$APP/Contents/Info.plist"

echo "==> done: $(pwd)/$APP"
