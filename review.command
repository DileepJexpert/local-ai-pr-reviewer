#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo
echo "============================================="
echo "            LOCAL AI PR REVIEWER"
echo "============================================="
echo
read -r -p "Paste GitHub or Bitbucket PR/compare URL: " URL
read -r -p "Local repository folder (recommended for company Bitbucket; Enter uses cache): " REPO
read -r -p "AI executable [idfc-coder] (press Enter): " CODER
CODER="${CODER:-idfc-coder}"
echo
echo "Important: select 1, 2, or 3 only at the next 'Choice' question."
echo "Choose review mode:"
echo "  1) BASELINE - neutral IDFC review without custom ai-pr-review rules"
echo "  2) GUIDED   - use this project's custom ai-pr-review rules"
echo "  3) BOTH     - run baseline, then guided, on the same prepared PR snapshot"
echo
echo "After review: run ./review-comments.command to open local proposed comments."
read -r -p "Choice [2]: " MODE_CHOICE
case "${MODE_CHOICE:-2}" in
  1) REVIEW_MODE="baseline" ;;
  2) REVIEW_MODE="guided" ;;
  3) REVIEW_MODE="both" ;;
  *) echo "Invalid choice. Enter 1, 2, or 3."; exit 2 ;;
esac

"$SCRIPT_DIR/start-review.sh" --repo "$REPO" --url "$URL" --target main --coder "$CODER" --review-mode "$REVIEW_MODE"
echo
read -r -p "Press Enter to close..." _
