#!/bin/bash
# CostBar one-command installer
# Checks dependencies, builds the app locally, installs to /Applications, launches.
set -euo pipefail
cd "$(dirname "$0")"

echo "── CostBar installer ──────────────────────────"

# 1. Xcode Command Line Tools (provides swiftc)
if ! xcode-select -p >/dev/null 2>&1; then
  echo "✗ Xcode Command Line Tools missing."
  echo "  Run:  xcode-select --install"
  echo "  Then re-run this script."
  exit 1
fi
echo "✓ Swift compiler found"

# 2. Node / npm (for ccusage)
if ! command -v npm >/dev/null 2>&1; then
  echo "✗ npm not found."
  echo "  Install node first:  brew install node"
  echo "  Then re-run this script."
  exit 1
fi
echo "✓ npm found"

# 3. ccusage (computes API-equivalent costs from local Claude Code logs)
if ! command -v ccusage >/dev/null 2>&1; then
  echo "… installing ccusage globally"
  npm install -g ccusage
fi
echo "✓ ccusage installed"

# 4. Claude Code login (needed for true billing numbers)
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo "⚠ No Claude Code login found in Keychain."
  echo "  True billing will be unavailable until you run 'claude' and log in."
fi

# 5. Build + install
bash build.sh

# 6. Launch
open /Applications/CostBar.app
echo ""
echo "✓ Done. Look for the dollar amount in your menu bar."
echo "  First refresh takes ~10 seconds."
echo "  If macOS asks about Keychain access, click 'Always Allow'."
