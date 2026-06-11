#!/bin/bash
# Build CostBar.app and install to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="/Applications/CostBar.app"

echo "Compiling..."
mkdir -p build
swiftc -O main.swift -o build/CostBar

echo "Assembling bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
cp build/CostBar "$APP/Contents/MacOS/"

codesign --force --sign - "$APP"

echo "Installed: $APP"
