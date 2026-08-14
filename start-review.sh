#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./start-review.sh --repo /path/to/repo --url <GitHub-or-Bitbucket-URL> [--source branch] [--target main] [--coder idfc-coder]"
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

REPO="" URL="" SOURCE="" TARGET="main" CODER="${IDFC_CODER_CMD:-idfc-coder}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --coder) CODER="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$REPO" && -n "$URL" ]] || { usage; exit 2; }
PATH_PART="${URL%%\?*}"
QUERY="${URL#*\?}"; [[ "$URL" == *\?* ]] || QUERY=""
if [[ -n "$SOURCE" ]]; then
  : # Explicit source/target is supported for any URL, including a PR overview page.
elif [[ "$PATH_PART" == https://github.com/* && "$PATH_PART" == */compare/* ]]; then
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
elif [[ "$PATH_PART" =~ /projects/[^/]+/repos/[^/]+/pull-requests/([0-9]+)(/|$) ]]; then
  PR_ID="${BASH_REMATCH[1]}"
  FROM_REF="refs/remotes/origin/ai-pr-reviewer/pr/${PR_ID}/from"
  TO_REF="refs/remotes/origin/ai-pr-reviewer/pr/${PR_ID}/to"
  echo "Resolving Bitbucket pull request $PR_ID from the repository remote..."
  git -C "$REPO" fetch origin \
    "+refs/pull-requests/${PR_ID}/from:${FROM_REF}" \
    "+refs/pull-requests/${PR_ID}/to:${TO_REF}"
  SOURCE="$(git -C "$REPO" rev-parse "$FROM_REF")"
  TARGET="$(git -C "$REPO" rev-parse "$TO_REF")"
else
  echo "ERROR: Could not determine branches from this URL. Pass --source <branch> --target <branch>, or use a GitHub/Bitbucket compare URL or Bitbucket PR overview URL." >&2
  exit 2
fi
[[ -n "$SOURCE" ]] || { echo "ERROR: Could not determine the source branch from the URL." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDFC_CODER_CMD="$CODER" IDFC_CODER_MODE=stdin "$SCRIPT_DIR/review-pr.sh" \
  --repo "$REPO" --source "$SOURCE" --target "$TARGET" --pr "compare-${SOURCE//\//_}"
