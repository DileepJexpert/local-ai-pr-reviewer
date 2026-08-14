#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./start-review.sh --repo /path/to/repo --url https://github.com/owner/repo/compare/branch [--target main] [--coder idfc-coder]"
}

REPO="" URL="" TARGET="main" CODER="${IDFC_CODER_CMD:-idfc-coder}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --coder) CODER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$REPO" && -n "$URL" ]] || { usage; exit 2; }
PATH_PART="${URL%%\?*}"
PREFIX="https://github.com/"
[[ "$PATH_PART" == "$PREFIX"* && "$PATH_PART" == */compare/* ]] || {
  echo "ERROR: URL must be a GitHub compare URL." >&2; exit 2;
}
RANGE="${PATH_PART#*/compare/}"
if [[ "$RANGE" == *...* ]]; then
  TARGET="${RANGE%%...*}"
  SOURCE="${RANGE#*...}"
else
  SOURCE="$RANGE"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDFC_CODER_CMD="$CODER" IDFC_CODER_MODE=stdin "$SCRIPT_DIR/review-pr.sh" \
  --repo "$REPO" --source "$SOURCE" --target "$TARGET" --pr "github-${SOURCE//\//_}"
