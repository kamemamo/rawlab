#!/bin/zsh
# RawLab.app を作る(自分用・署名なし)。使い方: ./scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."
(cd rawler-ffi && cargo build --release)
swift build -c release --product RawLabApp
APP=build/RawLab.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/RawLabApp "$APP/Contents/MacOS/RawLab"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.rawlab</string>
  <key>CFBundleName</key><string>RawLab</string>
  <key>CFBundleExecutable</key><string>RawLab</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "✓ $APP"
