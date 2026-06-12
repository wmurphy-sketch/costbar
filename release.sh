#!/bin/bash
# Build a distributable CostBar.app zip (compiled once, runs anywhere macOS 14+).
# Maintainer-only — produces dist/CostBar.zip to attach to a GitHub Release.
set -euo pipefail
cd "$(dirname "$0")"

echo "Compiling universal release (arm64 + x86_64, macOS 14+)..."
mkdir -p build dist
# Build each arch, then lipo into one universal binary so it runs on any Mac.
swiftc -O -target arm64-apple-macosx14.0  main.swift -o build/CostBar-arm64
if swiftc -O -target x86_64-apple-macosx14.0 main.swift -o build/CostBar-x86_64 2>/dev/null; then
  lipo -create build/CostBar-arm64 build/CostBar-x86_64 -output build/CostBar
  echo "  → universal (arm64 + x86_64)"
else
  cp build/CostBar-arm64 build/CostBar
  echo "  ⚠ x86_64 slice unavailable on this toolchain — shipping arm64-only"
fi

APP="dist/CostBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
cp build/CostBar "$APP/Contents/MacOS/"
codesign --force --sign - "$APP"

echo "Zipping..."
( cd dist && rm -f CostBar.zip && /usr/bin/ditto -c -k --keepParent CostBar.app CostBar.zip )

echo "Built: dist/CostBar.zip"
echo "Arch:  $(uname -m)  (note: this binary is $(uname -m)-only)"
