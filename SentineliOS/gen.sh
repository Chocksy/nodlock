#!/usr/bin/env bash
# Generate Sentinel.xcodeproj. Put YOUR ids in SentineliOS/.env (gitignored):
#   SENTINEL_BUNDLE_PREFIX=com.yourname.sentinel
#   SENTINEL_BUNDLE_ID=com.yourname.sentinel.ios
#   SENTINEL_TEAM_ID=YOURTEAMID
# Without .env, neutral placeholders are used (set your Team in Xcode before running).
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && set -a && . ./.env && set +a
export SENTINEL_BUNDLE_PREFIX="${SENTINEL_BUNDLE_PREFIX:-com.example.sentinel}"
export SENTINEL_BUNDLE_ID="${SENTINEL_BUNDLE_ID:-com.example.sentinel.ios}"
export SENTINEL_TEAM_ID="${SENTINEL_TEAM_ID:-}"
xcodegen generate
