#!/bin/bash
# 빌드 후 /Applications/SnapStack.app 에 설치하고 실행한다
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SnapStack.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macos15.0 Sources/*.swift -o "$APP/Contents/MacOS/SnapStack"
cp Info.plist "$APP/Contents/"
if [[ ! -f Icon/AppIcon.icns ]]; then
  (cd Icon && swift make_icon.swift icon_1024.png && rm -rf AppIcon.iconset && mkdir AppIcon.iconset \
    && for s in 16 32 128 256 512; do
         sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
         sips -z $((s*2)) $((s*2)) icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
       done && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset)
fi
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - --identifier com.seoune.snapstack "$APP"
[[ "${1:-}" == "--no-install" ]] && exit 0
pkill -x SnapStack || true
rm -rf /Applications/SnapStack.app ~/Applications/SnapStack.app
cp -R "$APP" /Applications/
touch /Applications/SnapStack.app
open /Applications/SnapStack.app
