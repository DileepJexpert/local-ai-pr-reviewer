#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./start-review.sh --repo /path/to/repo --url <GitHub-or-Bitbucket-compare-URL> [--target main] [--coder idfc-coder]"
}

url_decode() {
  local value="${1//+/ }"
  printf '%b' "${value//%/\\x}"
}
query_value() {
  local query="$1" key="$2" pair name value
  IFS='&' read -r -a pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    name="${pair%%=*}"; value="${pair#*=}"
    [[ "$name" == "$key" ]] && { url_decode "$value"; return 0; }
  done
  return 1
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
QUERY="${URL#*\?}"; [[ "$URL" == *\?* ]] || QUERY=""
if [[ "$PATH_PART" == https://github.com/* && "$PATH_PART" == */compare/* ]]; then
  RANGE="$(url_decode "${PATH_PART#*/compare/}")"
  if [[ "$RANGE" == *...* ]]; then
    TARGET="${RANGE%%...*}"
    SOURCE="${RANGE#*...}"
  else
    SOURCE="$RANGE"
  fi
elif [[ "$PATH_PART" == */branches/compare/* ]]; then
  RANGE="$(url_decode "${PATH_PART#*/branches/compare/}")"
  [[ "$RANGE" == *..* ]] || { echo "ERROR: Bitbucket Cloud compare URL must contain source..target." >&2; exit 2; }
  SOURCE="${RANGE%%..*}"
  TARGET="${RANGE#*..}"
elif [[ "$PATH_PART" == */compare && -n "$QUERY" ]]; then
  SOURCE="$(query_value "$QUERY" sourceBranch || true)"
  TARGET_FROM_URL="$(query_value "$QUERY" targetBranch || true)"
  [[ -n "$SOURCE" && -n "$TARGET_FROM_URL" ]] || { echo "ERROR: Bitbucket Server compare URL needs sourceBranch and targetBranch query parameters." >&2; exit 2; }
  SOURCE="${SOURCE#refs/heads/}"
  TARGET="${TARGET_FROM_URL#refs/heads/}"
else
  echo "ERROR: URL must be a GitHub compare URL, Bitbucket Cloud branches/compare URL, or Bitbucket Server compare?sourceBranch=...&targetBranch=... URL." >&2
  exit 2
fi
[[ -n "$SOURCE" ]] || { echo "ERROR: Could not determine the source branch from the URL." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDFC_CODER_CMD="$CODER" IDFC_CODER_MODE=stdin "$SCRIPT_DIR/review-pr.sh" \
  --repo "$REPO" --source "$SOURCE" --target "$TARGET" --pr "compare-${SOURCE//\//_}"
