#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

./macOS/build.sh
app=dist/Voltide.app
version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/Voltide")
output="dist/Voltide-$version-macOS-$arch.dmg"

stage=$(mktemp -d "dist/.dmg-XXXXXX")
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/contents"
ditto "$app" "$stage/contents/Voltide.app"
ln -s /Applications "$stage/contents/Applications"
codesign --verify --strict "$stage/contents/Voltide.app"

hdiutil create -srcfolder "$stage/contents" -volname "Voltide $version" \
    -fs HFS+ -format UDZO "$stage/installer.dmg"
hdiutil verify "$stage/installer.dmg"
mv "$stage/installer.dmg" "$output"
echo "$output"
