#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DB_PATH="$SCRIPT_DIR/data/icons.sqlite"
IMAGES_ROOT="$SCRIPT_DIR/data/pravicon_images"
OUTPUT_DIR="$PROJECT_DIR/RussianOrthodoxReader/Resources/Icons"

echo "Rebuilding icons.sqlite..."
python3 "$SCRIPT_DIR/build_icons_db.py" \
  --images-dir "$IMAGES_ROOT" \
  --output "$DB_PATH"

echo ""
echo "Building Vision feature index..."
ICON_DB_PATH="$DB_PATH" \
ICON_IMAGES_ROOT="$IMAGES_ROOT" \
ICON_OUTPUT_DIR="$OUTPUT_DIR" \
ICON_CLASSIFIER_PRIORS_ENABLED=true \
swift -module-cache-path /tmp/icon-feature-script-cache -e "$(tail -n +2 "$SCRIPT_DIR/build_icon_feature_index.swift")"

echo ""
echo "Icon identification assets are ready in:"
echo "  $OUTPUT_DIR"
