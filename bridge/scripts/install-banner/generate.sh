#!/bin/bash
# Generate install banner and QR code for README
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ICON="$ROOT/apps/mobile/fastlane/metadata/android/en-US/images/icon.png"
QR_OUTPUT="$ROOT/docs/images/install-qr.png"
BANNER_OUTPUT="$ROOT/docs/images/install-banner.png"
BANNER_JA_OUTPUT="$ROOT/docs/images/install-banner-ja.png"

# 1. Generate QR code with embedded icon
echo "🔲 Generating QR code..."
python3 "$SCRIPT_DIR/generate-qr.py"

# 2. Generate banners from HTML templates
echo "🎨 Generating install banners..."

TEMP_HTML="$SCRIPT_DIR/_temp_banner.html"

# English
sed -e "s|ICON_PATH|file://${ICON}|g" \
    -e "s|QR_PATH|file://${QR_OUTPUT}|g" \
    "$SCRIPT_DIR/template.html" > "$TEMP_HTML"

npx playwright screenshot \
  --viewport-size "900,420" \
  "file://${TEMP_HTML}" \
  "${BANNER_OUTPUT}"

# Japanese
sed -e "s|ICON_PATH|file://${ICON}|g" \
    -e "s|QR_PATH|file://${QR_OUTPUT}|g" \
    "$SCRIPT_DIR/template.ja.html" > "$TEMP_HTML"

npx playwright screenshot \
  --viewport-size "900,420" \
  "file://${TEMP_HTML}" \
  "${BANNER_JA_OUTPUT}"

rm -f "$TEMP_HTML"

echo "✅ Banner (EN): ${BANNER_OUTPUT}"
echo "✅ Banner (JA): ${BANNER_JA_OUTPUT}"
echo "✅ QR:          ${QR_OUTPUT}"
echo ""
echo "🎉 Done!"
