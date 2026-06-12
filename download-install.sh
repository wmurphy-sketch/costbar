#!/bin/bash
# CostBar — download the prebuilt app. No Xcode, no compiling, no clone.
#   curl -fsSL https://raw.githubusercontent.com/wmurphy-sketch/costbar/main/download-install.sh | bash
set -euo pipefail

REPO="wmurphy-sketch/costbar"
APP="/Applications/CostBar.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "── CostBar installer ──────────────────────────"

# 1. ccusage (the only runtime dependency — for the activity-estimate chart)
if ! command -v ccusage >/dev/null 2>&1; then
  if command -v npm >/dev/null 2>&1; then
    echo "… installing ccusage"
    npm install -g ccusage >/dev/null 2>&1 || echo "  (ccusage install failed — the chart will be empty until you install it: npm i -g ccusage)"
  else
    echo "⚠ node/npm not found — install it (brew install node) for the usage chart."
    echo "  The app still runs and shows real billing without it."
  fi
fi

# 2. download the latest release zip
echo "… downloading latest release"
URL="https://github.com/$REPO/releases/latest/download/CostBar.zip"
if ! curl -fsSL "$URL" -o "$TMP/CostBar.zip"; then
  echo "✗ Couldn't download $URL"
  echo "  Check that a release with CostBar.zip exists at https://github.com/$REPO/releases"
  exit 1
fi

# 3. unzip + install
echo "… installing to /Applications"
/usr/bin/ditto -x -k "$TMP/CostBar.zip" "$TMP"
pkill -x CostBar 2>/dev/null || true
rm -rf "$APP"
cp -R "$TMP/CostBar.app" "$APP"

# 4. clear the quarantine flag so Gatekeeper doesn't block the ad-hoc-signed app
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# 5. launch
open "$APP"
echo ""
echo "✓ Done — look for the dollar amount in your menu bar."
echo "  Requires Claude Code installed + logged in. First refresh takes ~10s."
echo "  If macOS asks about Keychain access, click 'Always Allow'."
