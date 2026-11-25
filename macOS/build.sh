#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=dist/Voltide.app
iconset=dist/Voltide.iconset
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset" dist/ModuleCache
xcrun swift -module-cache-path dist/ModuleCache macOS/tools/make-icon.swift app.ico "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/Voltide.icns"
xcrun swiftc -O -parse-as-library -module-cache-path dist/ModuleCache \
    -target "$(uname -m)-apple-macos27.0" macOS/*.swift -o "$app/Contents/MacOS/Voltide"
cp macOS/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
