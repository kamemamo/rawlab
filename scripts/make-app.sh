#!/bin/zsh
# RawLab.app を作る(自分のMac用・簡易署名)。使い方: ./scripts/make-app.sh
# 知り合いに配る版は scripts/make-dist.sh(ライブラリ同梱・Developer ID 署名・公証)
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.1.0}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
BUNDLE_ID=${BUNDLE_ID:-io.github.kamemamo.rawlab}
(cd rawler-ffi && cargo build --release)
swift build -c release --product RawLabApp
APP=build/RawLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/RawLabApp "$APP/Contents/MacOS/RawLab"

# アイコン: Resources/AppIcon.png(scripts/make-icon.swift で生成)から .icns を作る
[ -f Resources/AppIcon.png ] || swift scripts/make-icon.swift Resources/AppIcon.png
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>RawLab</string>
  <key>CFBundleExecutable</key><string>RawLab</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"
