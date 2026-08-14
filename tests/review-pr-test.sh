#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/review-pr.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/local-ai-pr-reviewer-test.XXXXXX")"

cleanup() {
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_not_exists() {
  [[ ! -e "$1" ]] || fail "unexpected path: $1"
}

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git init -q "$repo"
  git -C "$repo" config user.email reviewer-test@example.invalid
  git -C "$repo" config user.name reviewer-test
  # Exercise actual symlink checkout behavior even on Git for Windows.
  git -C "$repo" config core.symlinks true
  printf 'base\n' > "$repo/application.txt"
  git -C "$repo" add application.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb feature
  printf 'feature\n' >> "$repo/application.txt"
  git -C "$repo" commit -qam feature
}

FAKE_AGENT="$TEST_ROOT/fake-agent"
cat > "$FAKE_AGENT" <<'EOF_AGENT'
#!/usr/bin/env bash
set -euo pipefail
task="$(cat)"
report="$(printf '%s\n' "$task" | sed -n 's/^Create `\([^`]*\)` with this structure:$/\1/p' | head -n 1)"
[[ -n "$report" ]] || exit 20
printf '# AI PR Architecture Review\n\n## Final Recommendation\nAPPROVE\n' > "$report"
comments="$(printf '%s\n' "$task" | sed -n 's/^Create `\([^`]*proposed-pr-comments\.tsv\)`.*/\1/p' | head -n 1)"
if [[ -n "$comments" ]]; then
  printf '# id\tdisposition\tfile\tline\ttitle\tcomment\nF-1\tINLINE\tapplication.txt\t2\tSample issue\tSample verified review comment.\n' > "$comments"
fi
EOF_AGENT
chmod +x "$FAKE_AGENT"

TRANSCRIPT_AGENT="$TEST_ROOT/transcript-agent"
cat > "$TRANSCRIPT_AGENT" <<'EOF_TRANSCRIPT_AGENT'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'Completed read-only review. Finding: example evidence-backed observation.\n'
EOF_TRANSCRIPT_AGENT
chmod +x "$TRANSCRIPT_AGENT"

run_success() {
  local repo="$1"
  local output="$TEST_ROOT/reports/$(basename "$repo")"
  AI_PR_REVIEW_REPORT_ROOT="$output" IDFC_CODER_MODE=stdin IDFC_CODER_CMD="$FAKE_AGENT" bash "$SCRIPT" --repo "$repo" --source feature --target master >/dev/null
  local reports
  reports="$(find "$output" -name 'review.md' -type f)"
  [[ -n "$reports" ]] || fail "successful review did not create a report"
  assert_file "$(dirname "$reports")/proposed-pr-comments.tsv"
  assert_file "$(dirname "$reports")/proposed-pr-comments.html"
}

test_malicious_ai_review_symlink() {
  local repo="$TEST_ROOT/symlink-repo" outside="$TEST_ROOT/outside"
  make_repo "$repo"
  mkdir "$outside"
  ln -s "$outside" "$repo/.ai-review"
  # Stage a mode-120000 entry explicitly; this works even where Git for Windows
  # does not auto-detect a filesystem symlink.
  local blob
  blob="$(printf '%s' "$outside" | git -C "$repo" hash-object -w --stdin)"
  git -C "$repo" update-index --add --cacheinfo "120000,$blob,.ai-review"
  git -C "$repo" commit -qm malicious-symlink
  run_success "$repo"
  [[ -z "$(find "$outside" -mindepth 1 -print -quit)" ]] || fail "wrote reviewer files through PR-controlled symlink"
}

test_preexisting_legacy_worktree_path() {
  local repo="$TEST_ROOT/collision-repo" legacy
  make_repo "$repo"
  legacy="${TMPDIR:-/tmp}/ai-pr-review-feature-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$legacy"
  printf preserve > "$legacy/sentinel"
  run_success "$repo"
  assert_file "$legacy/sentinel"
  rm -rf "$legacy"
}

test_worktree_add_failure() {
  local repo="$TEST_ROOT/add-failure-repo" bin="$TEST_ROOT/failing-git-bin" recorded="$TEST_ROOT/worktree-path"
  make_repo "$repo"
  mkdir "$bin"
  cat > "$bin/git" <<'EOF_GIT'
#!/usr/bin/env bash
if [[ "$1" == "-C" && "$3" == "worktree" && "$4" == "add" ]]; then
  printf '%s' "$6" > "$RECORDED_WORKTREE"
  exit 42
fi
exec "$REAL_GIT" "$@"
EOF_GIT
  chmod +x "$bin/git"
  if PATH="$bin:$PATH" REAL_GIT="$(command -v git)" RECORDED_WORKTREE="$recorded" AI_PR_REVIEW_REPORT_ROOT="$TEST_ROOT/reports" IDFC_CODER_MODE=stdin IDFC_CODER_CMD="$FAKE_AGENT" bash "$SCRIPT" --repo "$repo" --source feature --target master >/dev/null 2>&1; then
    fail "review unexpectedly succeeded after worktree-add failure"
  fi
  assert_file "$recorded"
  assert_not_exists "$(cat "$recorded")"
}

test_no_origin() {
  local repo="$TEST_ROOT/no-origin-repo"
  make_repo "$repo"
  [[ -z "$(git -C "$repo" remote)" ]] || fail "test repository unexpectedly has a remote"
  run_success "$repo"
}

test_command_metacharacters() {
  local repo="$TEST_ROOT/metachar-repo" marker="$TEST_ROOT/metachar-ran"
  make_repo "$repo"
  if IDFC_CODER_MODE=stdin IDFC_CODER_CMD="$FAKE_AGENT; touch $marker" bash "$SCRIPT" --repo "$repo" --source feature --target master >/dev/null 2>&1; then
    fail "shell metacharacters in IDFC_CODER_CMD were accepted"
  fi
  assert_not_exists "$marker"
}

test_normal_successful_flow() {
  local repo="$TEST_ROOT/success-repo"
  make_repo "$repo"
  run_success "$repo"
}

test_transcript_fallback() {
  local repo="$TEST_ROOT/transcript-fallback-repo" output="$TEST_ROOT/transcript-reports"
  make_repo "$repo"
  AI_PR_REVIEW_REPORT_ROOT="$output" IDFC_CODER_MODE=stdin IDFC_CODER_CMD="$TRANSCRIPT_AGENT" bash "$SCRIPT" --repo "$repo" --source feature --target master >/dev/null
  local report
  report="$(find "$output" -name 'review.md' -type f -print -quit)"
  assert_file "$report"
  grep -q 'captured IDFC Coder transcript' "$report" || fail "transcript fallback was not saved as a report"
}

test_malicious_ai_review_symlink
test_preexisting_legacy_worktree_path
test_worktree_add_failure
test_no_origin
test_command_metacharacters
test_normal_successful_flow
test_transcript_fallback
echo "PASS: review-pr.sh security tests"
