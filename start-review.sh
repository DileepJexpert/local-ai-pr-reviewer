#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: ./start-review.sh --url <GitHub-or-Bitbucket-URL> [--repo /path/to/repo] [--cache-root ~/ai-pr-repos] [--clone-url URL] [--source branch] [--target main] [--coder idfc-coder] [--mode interactive|stdin|arg] [--review-mode baseline|guided|both]"
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

REPO="" URL="" SOURCE="" TARGET="main" CODER="${IDFC_CODER_CMD:-idfc-coder}" MODE="interactive" REVIEW_MODE="guided"
CACHE_ROOT="${AI_PR_REPOSITORY_CACHE:-$HOME/ai-pr-repos}" CLONE_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --cache-root) CACHE_ROOT="${2:-}"; shift 2 ;;
    --clone-url) CLONE_URL="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --coder) CODER="${2:-}"; shift 2 ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --review-mode) REVIEW_MODE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[[ -n "$URL" ]] || { usage; exit 2; }
[[ "$MODE" == 'interactive' || "$MODE" == 'stdin' || "$MODE" == 'arg' ]] || { echo "ERROR: --mode must be interactive, stdin, or arg." >&2; exit 2; }
[[ "$REVIEW_MODE" == 'baseline' || "$REVIEW_MODE" == 'guided' || "$REVIEW_MODE" == 'both' ]] || { echo "ERROR: --review-mode must be baseline, guided, or both." >&2; exit 2; }
PATH_PART="${URL%%\?*}"
QUERY="${URL#*\?}"; [[ "$URL" == *\?* ]] || QUERY=""
PROJECT_KEY="" REPO_SLUG="" DERIVED_CLONE_URL=""
if [[ "$PATH_PART" =~ ^https?://([^/]+)/projects/([^/]+)/repos/([^/]+) ]]; then
  BITBUCKET_HOST="${BASH_REMATCH[1]}"; PROJECT_KEY="${BASH_REMATCH[2]}"; REPO_SLUG="${BASH_REMATCH[3]}"
  DERIVED_CLONE_URL="https://${BITBUCKET_HOST}/scm/${PROJECT_KEY}/${REPO_SLUG}.git"
elif [[ "$PATH_PART" =~ ^https?://github.com/([^/]+)/([^/]+) ]]; then
  PROJECT_KEY="${BASH_REMATCH[1]}"; REPO_SLUG="${BASH_REMATCH[2]}"
  DERIVED_CLONE_URL="https://github.com/${PROJECT_KEY}/${REPO_SLUG}.git"
elif [[ "$PATH_PART" =~ ^https?://bitbucket.org/([^/]+)/([^/]+) ]]; then
  PROJECT_KEY="${BASH_REMATCH[1]}"; REPO_SLUG="${BASH_REMATCH[2]}"
  DERIVED_CLONE_URL="https://bitbucket.org/${PROJECT_KEY}/${REPO_SLUG}.git"
fi

if [[ -z "$REPO" ]]; then
  [[ -n "$REPO_SLUG" ]] || { echo "ERROR: Cannot derive a repository from this URL. Pass --repo explicitly." >&2; exit 2; }
  REPO="$CACHE_ROOT/$PROJECT_KEY/$REPO_SLUG"
  if [[ -d "$REPO/.git" ]]; then
    echo "Using cached repository: $REPO"
    git -C "$REPO" fetch --prune origin
  else
    if [[ -e "$REPO" ]]; then
      echo "ERROR: Repository cache path exists but is not a Git repository: $REPO" >&2
      echo "Use the local service folder, or move this incomplete cache folder aside before retrying." >&2
      exit 1
    fi
    mkdir -p "$(dirname "$REPO")"
    CLONE_URL="${CLONE_URL:-$DERIVED_CLONE_URL}"
    CLONE_TMP="$(mktemp -d "$(dirname "$REPO")/.ai-pr-review-clone.XXXXXX")"
    trap '[[ -n "${CLONE_TMP:-}" && -d "$CLONE_TMP" ]] && rm -rf -- "$CLONE_TMP"' EXIT
    echo "Caching repository for first use: $REPO"
    echo "Clone URL: $CLONE_URL"
    if ! git clone "$CLONE_URL" "$CLONE_TMP/repository"; then
      echo "ERROR: Could not clone the repository. For company Bitbucket, paste your already-cloned local service folder when prompted, or pass your organisation's authenticated SSH Clone URL with --clone-url." >&2
      exit 1
    fi
    mv "$CLONE_TMP/repository" "$REPO"
    rmdir "$CLONE_TMP" 2>/dev/null || true
    CLONE_TMP=""
  fi
fi
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
  git -C "$REPO" fetch origin "+refs/pull-requests/${PR_ID}/from:${FROM_REF}"
  SOURCE="$(git -C "$REPO" rev-parse "$FROM_REF")"
  if git -C "$REPO" fetch origin "+refs/pull-requests/${PR_ID}/to:${TO_REF}" 2>/dev/null; then
    TARGET="$(git -C "$REPO" rev-parse "$TO_REF")"
  else
    echo "Bitbucket does not expose the PR target ref; using --target $TARGET instead."
  fi
else
  echo "ERROR: Could not determine branches from this URL. Pass --source <branch> --target <branch>, or use a GitHub/Bitbucket compare URL or Bitbucket PR overview URL." >&2
  exit 2
fi
[[ -n "$SOURCE" ]] || { echo "ERROR: Could not determine the source branch from the URL." >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_PR_URL="$URL" IDFC_CODER_CMD="$CODER" IDFC_CODER_MODE="$MODE" "$SCRIPT_DIR/review-pr.sh" \
  --repo "$REPO" --source "$SOURCE" --target "$TARGET" --pr "compare-${SOURCE//\//_}" --review-mode "$REVIEW_MODE"
