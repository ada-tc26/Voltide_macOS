#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
app=dist/Voltide.app
mkdir -p "$app/Contents/MacOS" dist/ModuleCache
xcrun swiftc -O -parse-as-library -module-cache-path dist/ModuleCache \
    -target "$(uname -m)-apple-macos27.0" macOS/*.swift -o "$app/Contents/MacOS/Voltide"
cp macOS/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
