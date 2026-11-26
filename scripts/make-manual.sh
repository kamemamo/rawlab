#!/bin/zsh
# docs/manual/manual.html から配布用の PDF マニュアルを作る(Google Chrome で印刷)
set -euo pipefail
cd "$(dirname "$0")/.."
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT="docs/RawLab マニュアル.pdf"
"$CHROME" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf-no-header \
  --print-to-pdf="$PWD/$OUT" "file://$PWD/docs/manual/manual.html" 2>/dev/null
echo "✓ $OUT"
