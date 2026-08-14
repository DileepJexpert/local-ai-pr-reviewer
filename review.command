#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo
echo "============================================="
echo "            LOCAL AI PR REVIEWER"
echo "============================================="
echo
read -r -p "Paste GitHub compare URL: " URL
read -r -p "Local repository folder: " REPO
read -r -p "AI executable [idfc-coder]: " CODER
CODER="${CODER:-idfc-coder}"

"$SCRIPT_DIR/start-review.sh" --repo "$REPO" --url "$URL" --target main --coder "$CODER"
echo
read -r -p "Press Enter to close..." _
