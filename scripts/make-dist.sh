#!/bin/zsh
# 知り合いに配る RawLab を作る。
#   1. RawLab.app を作る(make-app.sh)
#   2. Homebrew のライブラリ(LibRaw・libomp・jpeg-turbo・lcms2)をアプリの中に入れる
#   3. ライセンス表記を入れる
#   4. Developer ID で署名(Hardened Runtime)
#   5. Apple の公証を受けて、結果をアプリに貼り付ける(staple)
#   6. 説明書(テキストと図入り PDF)と一緒に build/dist/RawLab-<版>.zip にまとめる
#
# 使い方:
#   ./scripts/make-dist.sh                 … 署名と公証まで
#   SKIP_NOTARIZE=1 ./scripts/make-dist.sh … 公証なし(確認用)
# 事前準備(1 回だけ。パスワードは自分で入力):
#   xcrun notarytool store-credentials rawlab-notary --apple-id <Apple ID> --team-id <チーム ID>
set -euo pipefail
cd "$(dirname "$0")/.."
export VERSION=${VERSION:-0.1.0}
NOTARY_PROFILE=${NOTARY_PROFILE:-rawlab-notary}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-0}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')}
[ -n "$IDENTITY" ] || { echo "Developer ID Application の証明書が見つかりません"; exit 1; }

./scripts/make-app.sh

DIST=build/dist
APP=$DIST/RawLab.app
rm -rf "$DIST" && mkdir -p "$DIST"
ditto build/RawLab.app "$APP"
EXE=$APP/Contents/MacOS/RawLab
FW=$APP/Contents/Frameworks
mkdir -p "$FW"

# --- 2. ライブラリを同梱して、アプリの中のものを読むように書き換える ---
LIBS=(
  /opt/homebrew/opt/libraw/lib/libraw_r.25.dylib
  /opt/homebrew/opt/libomp/lib/libomp.dylib
  /opt/homebrew/opt/jpeg-turbo/lib/libjpeg.8.dylib
  /opt/homebrew/opt/little-cms2/lib/liblcms2.2.dylib
)
for lib in $LIBS; do
  cp -L "$lib" "$FW/"
  chmod u+w "$FW/${lib:t}"
  install_name_tool -id "@rpath/${lib:t}" "$FW/${lib:t}" 2>/dev/null
done
fix_refs() {
  # /opt/homebrew を指している参照を @rpath に置き換える
  for dep in $(otool -L "$1" | awk 'NR>1 {print $1}' | grep '^/opt/homebrew' || true); do
    install_name_tool -change "$dep" "@rpath/${dep:t}" "$1" 2>/dev/null
  done
}
fix_refs "$EXE"
for f in $FW/*.dylib; do
  fix_refs "$f"
  install_name_tool -add_rpath @loader_path "$f" 2>/dev/null || true
done
install_name_tool -add_rpath @executable_path/../Frameworks "$EXE" 2>/dev/null

if otool -L "$EXE" $FW/*.dylib | grep -q /opt/homebrew; then
  echo "✗ まだ /opt/homebrew を参照しています"; otool -L "$EXE" $FW/*.dylib | grep /opt/homebrew; exit 1
fi

# --- 3. ライセンス表記 ---
LIC=$APP/Contents/Resources/Licenses
mkdir -p "$LIC"
cp THIRD_PARTY_NOTICES.md "$LIC/"
cp /opt/homebrew/opt/libraw/COPYRIGHT "$LIC/LibRaw-COPYRIGHT.txt"
cp /opt/homebrew/opt/libraw/LICENSE.LGPL "$LIC/LibRaw-LICENSE.LGPL.txt"
cp /opt/homebrew/opt/libraw/LICENSE.CDDL "$LIC/LibRaw-LICENSE.CDDL.txt"
cp /opt/homebrew/opt/libomp/LICENSE.TXT "$LIC/libomp-LICENSE.txt"
cp /opt/homebrew/opt/jpeg-turbo/LICENSE.md "$LIC/libjpeg-turbo-LICENSE.md"
cp /opt/homebrew/opt/little-cms2/LICENSE "$LIC/lcms2-LICENSE.txt"
RAWLER=$(ls -d ~/.cargo/registry/src/*/rawler-0.8.0 | head -1)
cp "$RAWLER/LICENSE" "$LIC/rawler-LICENSE.txt"

# --- 4. 署名(中身から順に。Hardened Runtime + タイムスタンプ) ---
for f in $FW/*.dylib; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$f"
done
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

# --- 5. 公証 ---
ZIP=$DIST/RawLab-$VERSION.zip
ditto -c -k --keepParent "$APP" "$ZIP"
if [ "$SKIP_NOTARIZE" != 1 ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm "$ZIP"
  # --- 6. 公証済みのアプリと説明書をまとめる ---
  PKG=$DIST/RawLab-$VERSION
  mkdir -p "$PKG"
  ditto "$APP" "$PKG/RawLab.app"
  cp docs/はじめにお読みください.txt "$PKG/"
  ./scripts/make-manual.sh >/dev/null
  cp "docs/RawLab マニュアル.pdf" "$PKG/"
  ditto -c -k --sequesterRsrc --keepParent "$PKG" "$ZIP"
  spctl -a -vv -t exec "$APP"
  echo "✓ $ZIP(公証済み)"
else
  echo "✓ $ZIP(公証なし・確認用)"
fi
