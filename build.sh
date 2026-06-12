#!/bin/bash
# Build CostBar.app and install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/CostBar.app"

# --- toolchain diagnostics ---------------------------------------------------
echo "Swift: $(swiftc --version 2>/dev/null | head -1 || echo 'not found')"
echo "Active developer dir: $(xcode-select -p 2>/dev/null || echo 'none')"

# Pin a deployment target so swiftc doesn't try to use a too-new SDK's features.
# Compiling against the installed SDK while targeting macOS 14 keeps it portable
# and avoids "SDK needs a newer Swift" failures on beta OSes.
TARGET="${COSTBAR_TARGET:-arm64-apple-macosx14.0}"
# Intel fallback
[ "$(uname -m)" = "x86_64" ] && TARGET="${COSTBAR_TARGET:-x86_64-apple-macosx14.0}"

echo "Compiling (target $TARGET)..."
mkdir -p build
if ! swiftc -O -target "$TARGET" main.swift -o build/CostBar 2> build/compile.log; then
  echo
  echo "✗ Compile failed. Full error:"
  echo "------------------------------------------------------------"
  cat build/compile.log
  echo "------------------------------------------------------------"
  echo
  echo "Common fixes:"
  echo "  • If it mentions a missing SDK or a Swift-version mismatch on a beta"
  echo "    macOS, install the full Xcode (App Store or developer.apple.com),"
  echo "    then:  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "  • If xcode-select points at 'none' above:  xcode-select --install"
  echo "  • To try a different deployment target:  COSTBAR_TARGET=arm64-apple-macosx15.0 bash build.sh"
  exit 1
fi

echo "Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
cp build/CostBar "$APP/Contents/MacOS/"

codesign --force --sign - "$APP"

echo "Installed: $APP"
