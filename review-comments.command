#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT_ROOT="$SCRIPT_DIR/reviews"

latest="$(find "$REPORT_ROOT" -maxdepth 1 -type d -name 'pr-*' -print 2>/dev/null | sort | tail -n 1 || true)"
if [[ -z "$latest" ]]; then
  echo "No saved review folders found in: $REPORT_ROOT"
  echo "Run a PR review first."
  exit 1
fi

proposal="$latest/proposed-pr-comments.html"
if [[ ! -f "$proposal" ]]; then
  proposal="$(find "$latest" -maxdepth 1 -type f -name 'proposed-pr-comments-*.html' -print 2>/dev/null | sort | tail -n 1 || true)"
fi
if [[ -z "$proposal" || ! -f "$proposal" ]]; then
  echo "This review has no proposed comments file. Run a new review using the latest reviewer version."
  exit 1
fi

echo "Opening local comment proposals: $proposal"
echo "Nothing will be posted automatically. Select only comments you agree with, then add them manually in Bitbucket."
if [[ "$(uname)" == "Darwin" ]]; then
  open "$proposal"
else
  echo "$proposal"
fi
