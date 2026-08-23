#!/usr/bin/env bash
# install.sh - one-command Nodlock installer for a fresh Mac.
#
# What you get: the Nodlock menu-bar app built from source, installed in
# ~/Applications, running at login, with ~/.config/op-guard/ set up. Pushes go
# to the native iOS app through APNs. The panel binds 127.0.0.1 and you reach it
# from the phone over your own Cloudflare Tunnel (or any URL you already control).
#
# Idempotent: re-running only creates what is missing. It never overwrites a
# value that already exists in ~/.config/op-guard/env. Steps that need a human
# (macOS permission toggles, Apple Developer signing) print instructions instead
# of failing, so the script always finishes and tells you what is left.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG_DIR="$HOME/.config/op-guard"
ENV_FILE="$CFG_DIR/env"
TOKEN_FILE="$CFG_DIR/panel-token"
APNS_DIR="$CFG_DIR/apns"
APP_SRC="$HERE/NodlockMac/Nodlock.app"
APP_DST="$HOME/Applications/Nodlock.app"

# LaunchAgent label. Use your own reverse-DNS prefix:
#   SENTINEL_LABEL=com.yourname.sentinel ./install.sh
LABEL="${SENTINEL_LABEL:-com.example.sentinel}"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"

# The panel always listens on loopback. Remote access is a tunnel's job.
BIND="127.0.0.1"
PORT="8377"
DEFAULT_URL="http://${BIND}:${PORT}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mxx \033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Prerequisites. Fail loudly on the ones we cannot work around, warn on the
#    optional ones so the install still completes.
# ---------------------------------------------------------------------------
say "Checking prerequisites"

[[ "$(uname -s)" == "Darwin" ]] || die "Nodlock is macOS only (this is $(uname -s))."

# swift ships with the Xcode command line tools. Without it there is no build.
if ! command -v swift >/dev/null 2>&1; then
  warn "swift not found. Install the Xcode command line tools:"
  warn ""
  warn "    xcode-select --install"
  warn ""
  die  "Re-run ./install.sh once the tools finish installing."
fi
say "swift: $(swift --version 2>/dev/null | head -1)"

# cloudflared is only needed to expose the panel to the phone from outside the
# LAN. Missing it is fine: everything still works on a local URL.
if command -v cloudflared >/dev/null 2>&1; then
  say "cloudflared: $(cloudflared --version 2>/dev/null | head -1)"
else
  warn "cloudflared not found (optional)."
  warn "  It is only needed for remote access to the panel from your phone."
  warn "  Install later with: brew install cloudflared"
fi

# ---------------------------------------------------------------------------
# 2. Config directory. The app mints the panel token itself on first run
#    (Config.swift, 16 random bytes -> 32 hex, chmod 600), so we only make sure
#    the directory exists and is private.
# ---------------------------------------------------------------------------
say "Preparing $CFG_DIR"
mkdir -p "$CFG_DIR" "$APNS_DIR"
chmod 700 "$CFG_DIR" "$APNS_DIR"
if [[ -s "$TOKEN_FILE" ]]; then
  chmod 600 "$TOKEN_FILE"
  say "panel token: already present"
else
  say "panel token: Nodlock will generate it on first launch"
fi

# ---------------------------------------------------------------------------
# 3. ~/.config/op-guard/env
# ---------------------------------------------------------------------------

# Append 'export KEY=VALUE' only when KEY is absent, so re-runs are safe.
set_env() {
  local key="$1" val="$2"
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
  if grep -q "^export ${key}=" "$ENV_FILE"; then
    say "env: $key already set, leaving it alone"
    return 0
  fi
  printf 'export %s=%s\n' "$key" "$val" >> "$ENV_FILE"
  say "env: set $key"
}

# Read a value back out of the env file (last wins, same as the app's parser).
get_env() {
  [[ -s "$ENV_FILE" ]] || return 0
  grep -E "^export ${1}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

touch "$ENV_FILE"; chmod 600 "$ENV_FILE"

set_env SENTINEL_BIND "$BIND"
set_env SENTINEL_PORT "$PORT"

# SENTINEL_URL is the base URL your PHONE uses to reach the panel. It is baked
# into the pairing QR, so it has to be reachable from the phone's network.
# Precedence: env var -> value already in the file -> prompt -> local default.
EXISTING_URL="$(get_env SENTINEL_URL)"
URL="${SENTINEL_URL:-$EXISTING_URL}"
if [[ -z "$URL" ]]; then
  cat <<PROMPT

  SENTINEL_URL is the address your phone will use for the panel.
    - Remote access: your own Cloudflare Tunnel hostname, e.g.
        https://nodlock.example.com
    - Same network only: a LAN or VPN address the phone can reach, e.g.
        http://192.168.1.42:${PORT}
    - Leave blank for ${DEFAULT_URL} (Mac only, the phone cannot reach it).

PROMPT
  # Non-interactive runs (CI, piped installs) skip the prompt and take the default.
  if [[ -t 0 ]]; then
    read -r -p "SENTINEL_URL [${DEFAULT_URL}]: " URL || true
  fi
  URL="${URL:-$DEFAULT_URL}"
fi
set_env SENTINEL_URL "$URL"
if [[ "$URL" == "$DEFAULT_URL" ]]; then
  warn "SENTINEL_URL is loopback. Your phone cannot reach that."
  warn "  For remote access, run a Cloudflare Tunnel to 127.0.0.1:${PORT}, then:"
  warn "  edit $ENV_FILE and set SENTINEL_URL to the public https hostname."
fi

# APNs settings go in as a commented block: you cannot fill them until you have
# an Apple Developer account, an App ID and a push key. Written once.
if ! grep -q 'OPG_APNS_TEAM_ID' "$ENV_FILE"; then
  say "env: adding APNs placeholders (commented)"
  cat >> "$ENV_FILE" <<'APNS'

# --- APNs (push to the native iOS app) -------------------------------------
# Nodlock pushes to your phone with a token-based (.p8) APNs key. Fill these
# in, uncomment, and restart Nodlock. Until then the Mac panel still works,
# you just get no push notifications.
#
#   1. developer.apple.com > Certificates, Identifiers & Profiles > Keys
#      > "+" > enable "Apple Push Notifications service (APNs)" > Continue.
#      Download AuthKey_XXXXXXXXXX.p8 (you only get ONE download).
#   2. Save it as:  ~/.config/op-guard/apns/AuthKey_<KEY_ID>.p8   (chmod 600)
#   3. KEY_ID  = the 10-char id shown next to the key.
#      TEAM_ID = developer.apple.com > Membership > Team ID (10 chars).
#      BUNDLE_ID = the iOS app's bundle identifier, from NodlockiOS/project.yml.
#   4. ENV: "sandbox" for a debug build from Xcode, "production" for TestFlight
#      or the App Store. Wrong value = pushes silently fail.
#
#export OPG_APNS_TEAM_ID=XXXXXXXXXX
#export OPG_APNS_KEY_ID=XXXXXXXXXX
#export OPG_APNS_BUNDLE_ID=com.example.sentinel.ios
#export OPG_APNS_ENV=sandbox
APNS
fi

# ---------------------------------------------------------------------------
# 4. Build and install the app.
# ---------------------------------------------------------------------------
say "Building Nodlock.app"
# build-app.sh ad-hoc signs by default and honours SIGN_IDENTITY. Ad-hoc is fine
# for local use; a Developer ID identity survives moving the bundle to another Mac.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  say "  signing identity: ${SIGN_IDENTITY}"
  ( cd "$HERE/NodlockMac" && SIGN_IDENTITY="$SIGN_IDENTITY" ./build-app.sh )
else
  say "  no SIGN_IDENTITY set, using ad-hoc signing"
  ( cd "$HERE/NodlockMac" && ./build-app.sh )
fi
[[ -d "$APP_SRC" ]] || die "build produced no bundle at $APP_SRC"

# Stop any running copy first, otherwise we would replace a bundle in use and
# macOS would keep the old TCC grants pointing at a deleted binary.
if [[ -f "$PLIST" ]]; then
  launchctl unload "$PLIST" >/dev/null 2>&1 || true
fi
pkill -f "$APP_DST/Contents/MacOS/Nodlock" >/dev/null 2>&1 || true

say "Installing to $APP_DST"
mkdir -p "$HOME/Applications"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# ---------------------------------------------------------------------------
# 5. LaunchAgent: start at login, restart on crash.
# ---------------------------------------------------------------------------
say "Installing LaunchAgent ($LABEL)"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${APP_DST}/Contents/MacOS/Nodlock</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/nodlock.out</string>
  <key>StandardErrorPath</key><string>/tmp/nodlock.out</string>
</dict></plist>
PLIST
# unload-then-load so a re-run picks up the fresh binary and plist.
launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load -w "$PLIST" >/dev/null 2>&1 \
  || warn "launchctl load failed. Run it by hand: launchctl load -w $PLIST"

# ---------------------------------------------------------------------------
# 6. macOS permissions. Only a human can flip these toggles, so we just open
#    the right panes and say what to click.
# ---------------------------------------------------------------------------
say "Opening the two Privacy panes"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" >/dev/null 2>&1 || true
sleep 1
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

cat <<DONE

------------------------------------------------------------------
Nodlock is installed. Four things left, in order:

  1. Grant the two permissions.
     System Settings > Privacy & Security, enable Nodlock under
     BOTH "Screen Recording" and "Accessibility".
     Screen Recording needs a relaunch:  launchctl kickstart -k gui/\$UID/${LABEL}

  2. Build the iOS app.
     Open NodlockiOS/ in Xcode, pick YOUR Apple Developer team, set
     your own bundle id, add the Push Notifications and Background
     Modes > Remote notifications capabilities, run it on your phone.
     Create an APNs .p8 key at developer.apple.com, drop it in
     ${APNS_DIR}/AuthKey_<KEY_ID>.p8, then fill in the
     OPG_APNS_* lines in ${ENV_FILE}.

  3. Optional: remote access.
     Run a Cloudflare Tunnel to http://${BIND}:${PORT}, put the public
     https hostname in SENTINEL_URL. Skip this if your phone already
     reaches the Mac on your own network.

  4. Pair.
     Click the Nodlock menu-bar icon > "Setup..." and scan the QR
     with the iOS app.

Config:      ${ENV_FILE}
Panel token: ${TOKEN_FILE}
Logs:        /tmp/nodlock.out
------------------------------------------------------------------
DONE
