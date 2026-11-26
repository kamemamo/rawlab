#!/bin/zsh
# docs/manual/manual.html から配布用の PDF マニュアルを作る(Google Chrome で印刷)
# 本文の {{VERSION}} は VERSION(make-dist.sh から渡る。既定は git の最新タグがなければ 0.0.0)に置き換える
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${VERSION:-0.0.0}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="docs/RawLab マニュアル.pdf"
TMP="docs/manual/.print.html"
sed "s/{{VERSION}}/$VERSION/g" docs/manual/manual.html > "$TMP"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf-no-header \
  --print-to-pdf="$PWD/$OUT" "file://$PWD/$TMP" 2>/dev/null
rm -f "$TMP"
echo "✓ $OUT(版 $VERSION)"
