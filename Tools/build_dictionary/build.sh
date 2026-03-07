#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build.sh  –  Build rus_dictionary.sqlite from Nyström's Biblical Dictionary
# ─────────────────────────────────────────────────────────────────────────────
set -e
cd "$(dirname "$0")"

echo "=== Russian Orthodox Reader — Dictionary Builder ==="
echo "Source: Нюстрем Э. Библейский словарь (1874, public domain)"
echo ""

# Check Python
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install Python 3.9+ first."
    exit 1
fi

# Install Python deps if needed
echo "Checking Python dependencies…"
python3 -c "import requests, bs4" 2>/dev/null || {
    echo "Installing: requests beautifulsoup4"
    pip3 install --quiet requests beautifulsoup4
}

echo "Building dictionary…"
python3 build.py

echo ""
echo "Done! Add RussianOrthodoxReader/Resources/Bible/rus_dictionary.sqlite"
echo "to your Xcode project (Bible group, target membership checked)."
