#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Local AI PR Reviewer

Usage:
  ./review-pr.sh --repo /path/to/repo --target develop [--source feature/branch] [--pr 1234] [--keep-worktree]

Examples:
  ./review-pr.sh --repo ~/work/payment-service --target develop
  ./review-pr.sh --repo ~/work/payment-service --source feature/consumer-request-lookup --target develop --pr 1234

Environment variables:
  IDFC_CODER_CMD   Command used to launch the internal coding agent. Default: idfc-coder
  IDFC_CODER_MODE  interactive | stdin | arg. Default: interactive

Notes:
  - interactive mode is safest when the exact idfc-coder CLI flags are unknown.
  - stdin mode passes the review task to the executable on standard input.
  - arg mode passes the review task as one argument to the executable.
  - IDFC_CODER_CMD must be one executable name or executable path; use a wrapper for fixed arguments.
USAGE
}

REPO=""
SOURCE=""
TARGET=""
PR_NUMBER="local"
KEEP_WORKTREE="false"
REVIEW_MODE="guided"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --pr) PR_NUMBER="${2:-}"; shift 2 ;;
    --review-mode) REVIEW_MODE="${2:-}"; shift 2 ;;
    --keep-worktree) KEEP_WORKTREE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$REPO" || -z "$TARGET" ]]; then
  usage
  exit 2
fi
if [[ "$REVIEW_MODE" != "baseline" && "$REVIEW_MODE" != "guided" && "$REVIEW_MODE" != "both" ]]; then
  echo "ERROR: --review-mode must be baseline, guided, or both." >&2
  exit 2
fi

REPO="$(cd "$REPO" && pwd)"

if ! git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: $REPO is not a Git repository." >&2
  exit 1
fi

IDFC_CODER_CMD="${IDFC_CODER_CMD:-idfc-coder}"
IDFC_CODER_MODE="${IDFC_CODER_MODE:-interactive}"

if [[ "$IDFC_CODER_MODE" != "interactive" && "$IDFC_CODER_MODE" != "stdin" && "$IDFC_CODER_MODE" != "arg" ]]; then
  echo "ERROR: IDFC_CODER_MODE must be interactive, stdin, or arg." >&2
  exit 1
fi

if ! command -v "$IDFC_CODER_CMD" >/dev/null 2>&1; then
  echo "ERROR: IDFC_CODER_CMD must name one executable available in PATH (or an executable path); shell syntax and arguments are not supported." >&2
  exit 1
fi

ORIGIN_URL="$(git -C "$REPO" remote get-url origin 2>/dev/null || true)"
echo "Repository: $REPO"
echo "Origin:     ${ORIGIN_URL:-<no origin>}"
if [[ -n "$ORIGIN_URL" ]]; then
  echo "Fetching latest refs..."
  git -C "$REPO" fetch --prune origin
else
  echo "No origin remote configured; using local refs."
fi

if [[ -z "$SOURCE" ]]; then
  SOURCE="$(git -C "$REPO" branch --show-current)"
  if [[ -z "$SOURCE" ]]; then
    echo "ERROR: Current checkout is detached. Pass --source explicitly." >&2
    exit 1
  fi
fi

resolve_ref() {
  local name="$1"
  if git -C "$REPO" rev-parse --verify --quiet "origin/$name" >/dev/null; then
    echo "origin/$name"
  elif git -C "$REPO" rev-parse --verify --quiet "$name" >/dev/null; then
    echo "$name"
  else
    return 1
  fi
}

SOURCE_REF="$(resolve_ref "$SOURCE")" || {
  echo "ERROR: Cannot resolve source branch '$SOURCE'." >&2
  exit 1
}
TARGET_REF="$(resolve_ref "$TARGET")" || {
  echo "ERROR: Cannot resolve target branch '$TARGET'." >&2
  exit 1
}

SAFE_SOURCE="$(printf '%s' "$SOURCE" | tr '/ :@' '____' | tr -cd '[:alnum:]_.-')"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/ai-pr-review-worktree.XXXXXX")"
REVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ai-pr-review-data.XXXXXX")"
WORKTREE_ADDED="false"
REPORT_ROOT="$SCRIPT_DIR/reviews"
REPORT_DIR="$REPORT_ROOT/pr-${PR_NUMBER}-${SAFE_SOURCE}-${STAMP}"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/review.md"
FINAL_HTML="$REPORT_DIR/review.html"
FINAL_LOG="$REPORT_DIR/agent.log"
RUN_LOG="$REPORT_DIR/review.log"
TASK_FILE="$REVIEW_DIR/REVIEW_TASK.md"
AGENT_REPORT="$REVIEW_DIR/ai-pr-review.md"
AGENT_LOG="$REVIEW_DIR/agent.log"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$RUN_LOG"
}

generate_html_report() {
  local markdown_file="$1" html_file="$2"
  {
    printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>AI PR Review</title><style>body{font:16px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;max-width:1000px;margin:40px auto;padding:0 24px;color:#172033;background:#f6f8fb}main{background:#fff;border-radius:12px;padding:28px;box-shadow:0 1px 4px #0002}pre{white-space:pre-wrap;word-wrap:break-word;line-height:1.5;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}</style></head><body><main><h1>AI Pull Request Review</h1><pre>'
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$markdown_file"
    printf '%s\n' '</pre></main></body></html>'
  } > "$html_file"
}

review_failed() {
  local exit_code="$1"
  [[ -f "$AGENT_LOG" ]] && cp "$AGENT_LOG" "$FINAL_LOG" 2>/dev/null || true
  echo
  echo "=============================================" >&2
  echo "REVIEW FAILED (exit code $exit_code)" >&2
  echo "Run log:   $RUN_LOG" >&2
  [[ -f "$FINAL_LOG" ]] && echo "Agent log: $FINAL_LOG" >&2
  echo "Report:    not created" >&2
  echo "=============================================" >&2
}
trap 'review_failed $?' ERR

cleanup() {
  if [[ "$KEEP_WORKTREE" == "true" ]]; then
    if [[ "$WORKTREE_ADDED" == "true" ]]; then
      echo "Keeping worktree: $WORKTREE"
      echo "Keeping review data: $REVIEW_DIR"
      log "Cleanup: retained worktree and reviewer data on request."
      return
    fi
  elif [[ "$WORKTREE_ADDED" == "true" ]]; then
    log "Cleanup: removing isolated worktree."
    git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || \
      echo "WARNING: Failed to remove registered worktree: $WORKTREE" >&2
  fi
  if [[ "$WORKTREE_ADDED" != "true" && -d "$WORKTREE" ]]; then
    # mktemp created this empty directory. Do not recursively delete a path after a failed add.
    rmdir "$WORKTREE" 2>/dev/null || true
  fi
  log "Cleanup: removing temporary reviewer data."
  rm -rf "$REVIEW_DIR"
}
trap cleanup EXIT

log "Stage 1/6: creating isolated worktree for source ref $SOURCE_REF."
git -C "$REPO" worktree add --detach "$WORKTREE" "$SOURCE_REF" >/dev/null
WORKTREE_ADDED="true"
log "Stage 1/6 complete: worktree created."

log "Stage 2/6: copying reviewer rules and freezing Git evidence."
if [[ "$REVIEW_MODE" != "baseline" ]]; then
  mkdir -p "$REVIEW_DIR/rules"
  cp -R "$SCRIPT_DIR/rules/." "$REVIEW_DIR/rules/"
fi

MERGE_BASE="$(git -C "$REPO" merge-base "$TARGET_REF" "$SOURCE_REF")"
SOURCE_SHA="$(git -C "$REPO" rev-parse "$SOURCE_REF")"
TARGET_SHA="$(git -C "$REPO" rev-parse "$TARGET_REF")"
log "Frozen refs: source=$SOURCE_SHA target=$TARGET_SHA merge-base=$MERGE_BASE"

# Collect deterministic PR context. The agent can use Git itself for deeper exploration.
log "Stage 3/6: generating changed-files list, diff statistics, full PR diff, and commit list."
git -C "$REPO" diff --name-status "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/changed-files.txt"
git -C "$REPO" diff --stat "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/diff-stat.txt"
git -C "$REPO" diff --find-renames --find-copies "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/pr.diff"
git -C "$REPO" log --oneline --decorate "$MERGE_BASE..$SOURCE_REF" > "$REVIEW_DIR/commits.txt"
log "Stage 3/6 complete: evidence files created."

cat > "$REVIEW_DIR/PR_CONTEXT.md" <<EOF_CONTEXT
# Pull Request Context

- PR: ${PR_NUMBER}
- Repository: ${ORIGIN_URL:-$REPO}
- Source branch: ${SOURCE}
- Target branch: ${TARGET}
- Source SHA: ${SOURCE_SHA}
- Target SHA: ${TARGET_SHA}
- Merge base: ${MERGE_BASE}
- Generated: $(date -Iseconds)

The checkout in this worktree is the PR source version.
Use the merge base and target ref for comparisons.
EOF_CONTEXT

cat > "$TASK_FILE" <<'EOF_TASK'
# AI Pull Request Architecture Review Task

You are an architecture-level reviewer working inside the checked-out source repository of a Pull Request.

## Non-negotiable review principle

Do NOT review only the diff. The diff identifies changed code; the repository provides the evidence required to understand the change.

No evidence means no finding.

Do not recommend an architectural mechanism merely because it is commonly used. A recommendation must solve a concrete failure, correctness, security, performance, compliance, compatibility, or operability scenario demonstrated by repository evidence.

## Inputs already prepared

Read these reviewer-controlled files first:

- `__REVIEW_DIR__/PR_CONTEXT.md`
- `__REVIEW_DIR__/changed-files.txt`
- `__REVIEW_DIR__/diff-stat.txt`
- `__REVIEW_DIR__/pr.diff`
- `__REVIEW_DIR__/commits.txt`

You may and should run Git/search/build/test commands and inspect any repository files needed for evidence. Do not modify application source code. Your only intended output file is `__AGENT_REPORT__` (plus temporary local analysis files under `__REVIEW_DIR__/` if needed).

## Stage 1 - Understand the PR

1. Determine the complete PR change from merge base to source HEAD.
2. Identify changed files, changed methods/classes/configuration, and important removed behavior.
3. Classify all affected areas, for example:
   - REST/API contract
   - Spring MVC/WebFlux
   - service/business logic
   - Kafka producer
   - Kafka consumer
   - Aerospike
   - Oracle/JPA/JDBC
   - transaction management
   - resilience
   - async/concurrency
   - security/authentication/authorization
   - configuration/secrets
   - observability/audit/logging
   - schema/migration
   - tests
   - build/dependencies
4. Do not deeply review technologies the PR does not affect unless execution-path analysis shows an indirect impact.

## Stage 2 - Build repository context

For each materially changed execution path:

1. Find callers and entry points.
2. Find callees and external boundaries.
3. Inspect interfaces and concrete implementations.
4. Inspect relevant Spring configuration and annotations.
5. Inspect relevant Kafka producer/consumer/error-handler/retry configuration.
6. Inspect relevant Aerospike client policies, key/query/scan/index usage, TTL and serialization configuration.
7. Inspect relevant Oracle/JPA/JDBC transaction, query, schema and migration behavior.
8. Inspect HTTP client timeout/retry/resilience behavior for any outbound calls.
9. Find similar existing implementations in this repository and determine established project conventions.
10. Inspect tests for the changed behavior.

Do not infer a project convention from one isolated occurrence if more context can be found.

## Stage 3 - Baseline review

Review all relevant changed behavior for:

- functional correctness
- edge cases and validation
- exception semantics
- null/not-found/duplicate handling
- security and authorization
- sensitive data / PII exposure
- auditability and traceability
- transaction boundaries
- distributed-system consistency
- backward compatibility
- configuration correctness
- concurrency/thread safety
- resource usage
- performance/scalability
- observability
- test adequacy
- rollout/rollback compatibility when applicable

Avoid duplicating findings better handled by compiler/formatter/static-style tools unless they create architectural or production impact.

## Stage 4 - Technology-specific review

### Spring
Check, where relevant:
- proxy-based annotation behavior and self-invocation
- `@Transactional` placement and propagation
- transactions held across remote I/O
- validation and exception translation
- bean lifecycle and thread safety
- async context propagation
- configuration externalization

### Kafka
Check, where relevant:
- idempotency
- duplicate delivery
- offset/ack behavior
- error handler and retry ownership
- DLT/retry-topic behavior
- partition key and ordering assumptions
- consumer concurrency/rebalancing implications
- producer delivery semantics
- schema/event compatibility
- side effects before acknowledgement

### Aerospike
Check, where relevant:
- primary-key/data-model suitability
- query versus direct key lookup
- scans on production paths
- secondary-index justification rather than automatic recommendation
- client timeout and retry policies
- record generation/concurrency behavior
- TTL and expiration semantics
- batch opportunities
- serialization/schema compatibility

### Oracle / relational database
Check, where relevant:
- transaction scope
- indexes/query access patterns
- locking/deadlock potential
- constraints and uniqueness
- migration compatibility
- N+1/query amplification
- connection-pool exposure
- external calls while transactions/connections remain held

## Stage 5 - Resilience and retry reasoning

Never automatically recommend `@Retryable` or `@CircuitBreaker`.

Before making any retry recommendation, determine as much as repository evidence permits:

- operation idempotency
- Kafka delivery retries
- Spring Retry / Resilience4j retries
- HTTP client retries
- SDK/client retries (including Aerospike)
- database retry behavior
- retryable versus permanent exception types
- timeout budget
- backoff policy
- caller retries
- approximate worst-case total attempts
- what happens after exhaustion

Explicitly detect nested retry amplification.

Before recommending a circuit breaker, identify:

- which dependency can fail
- expected failure duration/pattern
- synchronous impact on callers/threads
- configured timeouts
- intended open-circuit behavior
- fallback semantics
- interaction with Kafka retry/DLT or upstream retry

A circuit breaker is not automatically required for every external dependency.

## Stage 6 - Failure-mode simulation

For each important changed execution path, reason through applicable scenarios:

- normal success
- dependency timeout
- dependency unavailable
- partial success
- duplicate request/event
- concurrent execution
- pod/process termination at important boundaries
- retry after partial side effect
- malformed or unexpected input
- high load / burst
- stale or missing configuration
- old/new schema or event-version interaction

Pay special attention to distinguishing `NOT_FOUND` from `DEPENDENCY_UNAVAILABLE`.

## Stage 7 - Open-ended novel-risk discovery

Now deliberately ignore the predefined checklist.

Assume all previous checks missed something.

Re-read the diff and impacted execution paths as an experienced production architect and identify any NEW class of risk introduced by this PR that is not explicitly covered by the predefined categories.

Look for interactions between otherwise-correct components, new language/library patterns, unexpected lifecycle behavior, context propagation, sequencing issues, failure amplification, hidden assumptions, or technology-specific behavior.

Do not invent findings just to populate this section. It is valid to report that no additional evidence-backed novel risk was found.

## Stage 8 - Mandatory candidate verification and final judge

Before reading `__REVIEW_DIR__/rules/`, perform a neutral repository and architecture discovery phase. Inspect ADRs/design documents, the changed module, comparable recent modules, and relevant repository history; record the evidence and unknowns in the report. Do not assume DDD, MVC, hexagonal, clean architecture, CQRS, or another named architecture is preferred. Treat architecture drift separately from correctness: a different pattern is not a defect unless repository evidence shows it is unintentional and inconsistent with established conventions.

First perform blind/open-ended defect discovery without organisation rules, creating recommendation-free hypotheses only. Then read every file under `__REVIEW_DIR__/rules/` and perform a separate organisation-rule compliance pass. Keep those hypothesis origins distinct.

Use this mandatory sequence: PR diff → change classification → execution-path discovery → initial review → candidate findings → counter-evidence verification → final judge → report. A candidate BLOCKER or MAJOR must never go directly into the final report.

For each materially changed method, inspect direct callers, indirect callers when needed, direct callees, called helpers/private methods, interfaces/implementations, repositories, Spring annotations/transactions, JPA lifecycle and dirty checking, constraints/indexes/locking, configuration, related tests, and similar implementations. Do not stop at code that looks problematic. Read a called helper before deciding that it does not synchronize state.

For every candidate, independently try to disprove it. Do not create or reveal a recommendation to the verifier; give it only the hypothesis, evidence, scenario, and repository context. Search for relevant helpers, upstream/downstream validation, transaction propagation, dirty checking/save/flush timing, JPA locks, SELECT FOR UPDATE, optimistic locking, Java locks, unique/foreign/check constraints, upserts/triggers, idempotency/deduplication, retry/error handling, AOP/interceptors, configuration, and existing architectural utilities.

For concurrency/idempotency candidates, explicitly inspect upstream lock acquisition, transaction boundaries/propagation, `@Lock`, `PESSIMISTIC_WRITE`, `PESSIMISTIC_READ`, `@Version`, unique constraints, upsert/recovery, and serialized parent-resource access. Do not call a read-check-insert path unsafe until upstream serialization is ruled out.

For state-change candidates, explicitly inspect helpers, indirect setters, entity listeners, JPA dirty checking, save/flush, and transaction commit. Do not infer a field remains unchanged merely because the changed method lacks an explicit setter.

Before retaining BLOCKER or MAJOR, establish: exact event sequence; all participating code/config; prevention mechanisms inspected; why they do not prevent the failure; PR attribution; and direct evidence. Perform a prompt-bias self-check: reject a candidate that primarily exists because this prompt named retry, circuit breaker, locking, indexing, DDD, or another pattern unless independent repository evidence proves it. If evidence is incomplete, downgrade to QUESTION or reject. HIGH confidence requires relevant path/helper/transaction/concurrency/configuration inspection, completed counter-evidence verification, and no invalidating mechanism.

Record each candidate internally as CONFIRMED, DOWNGRADED, QUESTION, or REJECTED. Rejected candidates must not appear as PR findings. Existing target-branch issues go in `Pre-existing Architectural Observations` with `Introduced by PR: NO`; they must not cause CHANGES_REQUIRED. Novel-risk candidates follow this exact verification process.

## Stage 9 - Finding rules

Only a hypothesis that survived the independent counter-evidence pass may become a finding or receive a recommendation. Include the prompt-bias self-check and state separately whether it is a correctness defect, verified architecture drift, or neither.

Every finding must include:

- Severity: BLOCKER | MAJOR | MINOR | SUGGESTION | QUESTION
- Title
- Evidence: file path + line/method/configuration references
- Failure scenario / reasoning
- Impact
- Recommendation
- Confidence: HIGH | MEDIUM | LOW
- Introduced by PR: YES | NO
- Execution path
- Counter-evidence checked
- Why counter-evidence does not invalidate the finding

Rules:

1. No evidence -> no finding.
2. Never hide a genuine BLOCKER or MAJOR because of output limits.
3. Deduplicate findings that describe the same root cause.
4. Do not turn uncertainty into a command. Use QUESTION when design intent cannot be proven.
5. Do not recommend `@Retryable`, `@CircuitBreaker`, caching, a secondary index, async processing, a new transaction annotation, or audit logging without explaining the concrete scenario it solves.
6. Do not treat absence of a pattern as a defect unless project/organization policy or a demonstrated failure scenario requires it.
7. Distinguish code defects from governance/process gaps.
8. Keep style-only observations out unless they materially affect correctness or maintainability.

## Stage 10 - Tests

For every BLOCKER or MAJOR correctness/resilience finding, state the smallest useful test that would prove the expected behavior or prevent regression.

When claiming tests are missing, identify the exact behavior/scenario not covered. Do not merely say "add integration tests".

## Output

Create `__AGENT_REPORT__` with this structure:

# AI PR Architecture Review

## Executive Summary
- PR risk: LOW | MEDIUM | HIGH | CRITICAL
- Recommendation: APPROVE | APPROVE_WITH_COMMENTS | CHANGES_REQUIRED | ARCHITECT_REVIEW_REQUIRED
- 3-8 sentences explaining the material change and overall risk.

## Change Impact
Describe the affected execution paths and technologies.

## Review Verification
- Candidate findings: N
- Confirmed: N
- Downgraded: N
- Questions: N
- Rejected after counter-evidence: N

## Neutral Architecture Discovery
- ADR/design evidence, if any
- Current-module, comparable-module, and history evidence
- Discovered conventions and unresolved unknowns

## Blockers
All evidence-backed BLOCKER findings, or `None`.

## Major Findings
All evidence-backed MAJOR findings, or `None`.

## Minor Findings
Distinct evidence-backed MINOR findings, or `None`.

## Suggestions
Useful non-required improvements, or `None`.

## Architecture Questions
Questions where repository evidence is insufficient to safely prescribe a design.

## Novel Risks Discovered
Evidence-backed risks found by the open-ended pass that were not merely repeats of baseline checks, or `None`.

## Retry and Failure Strategy
Summarize retry ownership, timeouts, circuit-breaker behavior and nested-retry risks for affected paths. If not applicable, say so.

## Data and Transaction Consistency
Summarize relevant Oracle/Aerospike/Kafka consistency and transaction implications. If not applicable, say so.

## Test Gaps
Only specific missing behavior coverage.

## Checks With No Material Findings
Compact list only. Do not write a long paragraph per passed check.

## Final Recommendation
State the final merge recommendation and why.

At the end, verify every BLOCKER/MAJOR statement is supported by concrete repository evidence. Remove unsupported claims before saving the report.
EOF_TASK

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

REVIEW_DIR_FOR_SED="$(escape_sed_replacement "$REVIEW_DIR")"
AGENT_REPORT_FOR_SED="$(escape_sed_replacement "$AGENT_REPORT")"
sed \
  -e "s|__REVIEW_DIR__|$REVIEW_DIR_FOR_SED|g" \
  -e "s|__AGENT_REPORT__|$AGENT_REPORT_FOR_SED|g" \
  "$TASK_FILE" > "$TASK_FILE.rendered"
mv "$TASK_FILE.rendered" "$TASK_FILE"

# Add concrete refs to task without relying on template expansion above.
cat >> "$TASK_FILE" <<EOF_REFS

## Resolved Git refs for this review

- Source branch: ${SOURCE}
- Target branch: ${TARGET}
- Source ref: ${SOURCE_REF}
- Target ref: ${TARGET_REF}
- Merge base: ${MERGE_BASE}

Useful commands include:

\`git diff ${MERGE_BASE}...HEAD\`
\`git diff --name-status ${MERGE_BASE}...HEAD\`
\`git log --oneline ${MERGE_BASE}..HEAD\`
EOF_REFS

write_baseline_task() {
  local output_file="$1"
  local output_report="$2"
  cat > "$output_file" <<EOF_BASELINE
# Neutral Pull Request Review Task

Review the source checkout at: $WORKTREE
Use reviewer-controlled evidence at: $REVIEW_DIR

This is BASELINE mode. Do not read, load, quote, or apply the custom ai-pr-review rules. Review the whole frozen repository snapshot and merge-base diff for evidence-backed correctness, security, reliability, compatibility, and test issues. Do not assume a named architecture or a preferred pattern. Treat initial observations as hypotheses and independently look for counter-evidence before retaining them.

Read changed-files.txt, diff-stat.txt, pr.diff, commits.txt, and PR_CONTEXT.md. Do not write inside the source checkout.

Create the review report at: $output_report

Include: executive summary, change impact, findings with severity/evidence/failure scenario/impact/recommendation/confidence, positive observations, test gaps, and final recommendation. Do not report issues already present in the merge base.

Frozen refs: source=$SOURCE_SHA target=$TARGET_SHA merge-base=$MERGE_BASE
EOF_BASELINE
}

GUIDED_TASK_FILE="$TASK_FILE"
GUIDED_AGENT_REPORT="$AGENT_REPORT"
GUIDED_AGENT_LOG="$AGENT_LOG"
if [[ "$REVIEW_MODE" == "baseline" ]]; then
  rm -rf "$REVIEW_DIR/rules"
  write_baseline_task "$TASK_FILE" "$AGENT_REPORT"
elif [[ "$REVIEW_MODE" == "both" ]]; then
  GUIDED_TASK_FILE="$REVIEW_DIR/REVIEW_TASK.guided.md"
  mv "$TASK_FILE" "$GUIDED_TASK_FILE"
  BASELINE_TASK_FILE="$REVIEW_DIR/REVIEW_TASK.baseline.md"
  BASELINE_AGENT_REPORT="$REVIEW_DIR/ai-pr-review-baseline.md"
  BASELINE_AGENT_LOG="$REVIEW_DIR/agent-baseline.log"
  write_baseline_task "$BASELINE_TASK_FILE" "$BASELINE_AGENT_REPORT"
fi

cd "$WORKTREE"

echo
echo "Review worktree: $WORKTREE"
echo "Review task:     $TASK_FILE"
echo "Live run log:    $RUN_LOG"
echo

run_agent() {
  log "Stage 4/6: launching idfc-coder in $IDFC_CODER_MODE mode."
  case "$IDFC_CODER_MODE" in
    stdin)
      # For CLIs that accept the task on stdin.
      "$IDFC_CODER_CMD" < "$TASK_FILE" 2>&1 | tee "$AGENT_LOG"
      ;;
    arg)
      # For CLIs that accept a prompt as a positional argument.
      TASK_CONTENT="$(cat "$TASK_FILE")"
      "$IDFC_CODER_CMD" "$TASK_CONTENT" 2>&1 | tee "$AGENT_LOG"
      ;;
    interactive)
      INSTRUCTION="Read $TASK_FILE and execute the complete review. Create $AGENT_REPORT as instructed."
      if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$INSTRUCTION" | pbcopy
      fi
      echo
      echo "============================================="
      echo "ACTION REQUIRED - IDFC CODER IS ABOUT TO OPEN"
      echo "1. Click the IDFC Coder window."
      echo "2. Press Cmd + V to paste the review instruction."
      echo "3. Press Enter once."
      echo "4. When you see PLAN MODE / 'Shift+Tab to approve this plan': press Shift + Tab."
      echo "5. When you then see >>> EXECUTE MODE <<<: type Proceed at the > prompt and press Enter."
      echo "6. Wait until REVIEW COMPLETE appears; do not close Terminal."
      echo "============================================="
      if command -v osascript >/dev/null 2>&1; then
        osascript -e 'display dialog "IDFC Coder will open next.\n\n1. Click inside IDFC Coder.\n2. Press Command-V to paste the review instruction.\n3. Press Enter once.\n4. PLAN MODE: press Shift-Tab.\n5. EXECUTE MODE: type Proceed at the > prompt, then press Enter.\n6. Wait for REVIEW COMPLETE in Terminal.\n\nThe instruction is already copied to your clipboard." with title "Local AI PR Reviewer - Next Step" buttons {"Cancel", "Open IDFC Coder"} default button "Open IDFC Coder" with icon note'
      else
        read -r -p "Press Enter to open IDFC Coder, then paste with Cmd+V and press Enter: " _
      fi
      log "IDFC Coder is interactive. The review instruction is on the clipboard; paste it with Cmd+V, then press Enter."
      if command -v script >/dev/null 2>&1; then
        script -q "$AGENT_LOG" "$IDFC_CODER_CMD"
      else
        "$IDFC_CODER_CMD"
      fi
      ;;
  esac
  log "Stage 4/6 complete: idfc-coder exited."
}

run_single_review() {
  local label="$1" task="$2" report="$3" agent_log="$4" final_report="$5" final_log="$6" final_html
  TASK_FILE="$task"; AGENT_REPORT="$report"; AGENT_LOG="$agent_log"
  echo
  echo "========== $label REVIEW =========="
  echo "Task: $TASK_FILE"
  log "Starting $label review against the frozen source, target, and merge-base refs."
  run_agent
  if [[ ! -f "$AGENT_REPORT" ]]; then
    log "$label review stopped without creating its report."
    return 3
  fi
  cp "$AGENT_REPORT" "$final_report"
  [[ -f "$AGENT_LOG" ]] && cp "$AGENT_LOG" "$final_log"
  final_html="${final_report%.md}.html"
  generate_html_report "$final_report" "$final_html"
  log "$label review report saved: $final_report"
}

if [[ "$REVIEW_MODE" == "both" ]]; then
  BASELINE_FINAL_REPORT="${FINAL_REPORT%.md}-baseline.md"
  GUIDED_FINAL_REPORT="${FINAL_REPORT%.md}-guided.md"
  BASELINE_FINAL_LOG="${FINAL_LOG%.agent.log}-baseline.agent.log"
  GUIDED_FINAL_LOG="${FINAL_LOG%.agent.log}-guided.agent.log"
  COMPARISON_FILE="${FINAL_REPORT%.md}-comparison.md"
  run_single_review "BASELINE" "$BASELINE_TASK_FILE" "$BASELINE_AGENT_REPORT" "$BASELINE_AGENT_LOG" "$BASELINE_FINAL_REPORT" "$BASELINE_FINAL_LOG"
  run_single_review "GUIDED" "$GUIDED_TASK_FILE" "$GUIDED_AGENT_REPORT" "$GUIDED_AGENT_LOG" "$GUIDED_FINAL_REPORT" "$GUIDED_FINAL_LOG"
  cat > "$COMPARISON_FILE" <<EOF_COMPARISON
# Baseline and Guided Review Outputs

Both reviews used the same prepared worktree and frozen source SHA ($SOURCE_SHA), target SHA ($TARGET_SHA), and merge base ($MERGE_BASE).

- Baseline report: $BASELINE_FINAL_REPORT
- Guided report: $GUIDED_FINAL_REPORT

Compare the two reports to identify findings that appear only when custom ai-pr-review rules are applied.
EOF_COMPARISON
  COMPARISON_HTML="${COMPARISON_FILE%.md}.html"
  generate_html_report "$COMPARISON_FILE" "$COMPARISON_HTML"
  log "Both-mode comparison index saved: $COMPARISON_FILE"
  echo
  echo "============================================="
  echo "REVIEW COMPLETE - BOTH MODES"
  echo "Baseline:   $BASELINE_FINAL_REPORT"
  echo "Guided:     $GUIDED_FINAL_REPORT"
  echo "Comparison: $COMPARISON_FILE"
  echo "Open comparison: $COMPARISON_HTML"
  echo "Run log:    $RUN_LOG"
  echo "============================================="
  [[ "$(uname)" != "Darwin" ]] || open "$COMPARISON_HTML" || log "WARNING: could not open comparison HTML automatically."
else
  DISPLAY_MODE="$(printf '%s' "$REVIEW_MODE" | tr '[:lower:]' '[:upper:]')"
  run_single_review "$DISPLAY_MODE" "$TASK_FILE" "$AGENT_REPORT" "$AGENT_LOG" "$FINAL_REPORT" "$FINAL_LOG"
  log "Stage 6/6 complete: review output saved."
  echo
  echo "============================================="
  echo "REVIEW COMPLETE - $DISPLAY_MODE MODE"
  echo "Review folder: $REPORT_DIR"
  echo "Open review:  $FINAL_HTML"
  echo "Markdown:     $FINAL_REPORT"
  echo "Agent log:   $FINAL_LOG"
  echo "Run log:     $RUN_LOG"
  echo "============================================="
  [[ "$(uname)" != "Darwin" ]] || open "$FINAL_HTML" || log "WARNING: could not open review HTML automatically."
fi
