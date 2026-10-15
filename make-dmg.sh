#!/bin/bash
# 동료 공유용: 애플 실리콘·인텔 겸용으로 빌드해 dist/SnapStack.dmg 를 만든다
set -euo pipefail
cd "$(dirname "$0")"
B=build/universal
rm -rf "$B" dist
mkdir -p "$B" dist
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos15.0" Sources/*.swift -o "$B/$arch"
done
APP="$B/SnapStack.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "$B/arm64" "$B/x86_64" -output "$APP/Contents/MacOS/SnapStack"
cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
codesign --force -s - --identifier com.seoune.snapstack "$APP"
STAGE="$B/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname SnapStack -srcfolder "$STAGE" -ov -format UDZO dist/SnapStack.dmg >/dev/null
echo "dist/SnapStack.dmg"
