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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --pr) PR_NUMBER="${2:-}"; shift 2 ;;
    --keep-worktree) KEEP_WORKTREE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$REPO" || -z "$TARGET" ]]; then
  usage
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
REPORT_DIR="$SCRIPT_DIR/reviews"
mkdir -p "$REPORT_DIR"
FINAL_REPORT="$REPORT_DIR/pr-${PR_NUMBER}-${SAFE_SOURCE}-${STAMP}.md"
FINAL_LOG="$REPORT_DIR/pr-${PR_NUMBER}-${SAFE_SOURCE}-${STAMP}.agent.log"
TASK_FILE="$REVIEW_DIR/REVIEW_TASK.md"
AGENT_REPORT="$REVIEW_DIR/ai-pr-review.md"
AGENT_LOG="$REVIEW_DIR/agent.log"

cleanup() {
  if [[ "$KEEP_WORKTREE" == "true" ]]; then
    if [[ "$WORKTREE_ADDED" == "true" ]]; then
      echo "Keeping worktree: $WORKTREE"
      echo "Keeping review data: $REVIEW_DIR"
      return
    fi
  elif [[ "$WORKTREE_ADDED" == "true" ]]; then
    git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || \
      echo "WARNING: Failed to remove registered worktree: $WORKTREE" >&2
  fi
  if [[ "$WORKTREE_ADDED" != "true" && -d "$WORKTREE" ]]; then
    # mktemp created this empty directory. Do not recursively delete a path after a failed add.
    rmdir "$WORKTREE" 2>/dev/null || true
  fi
  rm -rf "$REVIEW_DIR"
}
trap cleanup EXIT

echo "Creating isolated review worktree..."
git -C "$REPO" worktree add --detach "$WORKTREE" "$SOURCE_REF" >/dev/null
WORKTREE_ADDED="true"

mkdir -p "$REVIEW_DIR/rules"
cp -R "$SCRIPT_DIR/rules/." "$REVIEW_DIR/rules/"

MERGE_BASE="$(git -C "$REPO" merge-base "$TARGET_REF" "$SOURCE_REF")"
SOURCE_SHA="$(git -C "$REPO" rev-parse "$SOURCE_REF")"
TARGET_SHA="$(git -C "$REPO" rev-parse "$TARGET_REF")"

# Collect deterministic PR context. The agent can use Git itself for deeper exploration.
git -C "$REPO" diff --name-status "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/changed-files.txt"
git -C "$REPO" diff --stat "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/diff-stat.txt"
git -C "$REPO" diff --find-renames --find-copies "$MERGE_BASE...$SOURCE_REF" > "$REVIEW_DIR/pr.diff"
git -C "$REPO" log --oneline --decorate "$MERGE_BASE..$SOURCE_REF" > "$REVIEW_DIR/commits.txt"

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

cd "$WORKTREE"

echo
echo "Review worktree: $WORKTREE"
echo "Review task:     $TASK_FILE"
echo

run_agent() {
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
      cat <<'INTERACTIVE'
The exact non-interactive syntax of your internal idfc-coder is organization-specific,
so interactive mode avoids inventing unsupported flags.

When idfc-coder opens, give it this single instruction:

  Read the review task path shown above and execute the complete review. Create the output report path specified in that task.

On macOS the instruction has also been copied to the clipboard when pbcopy is available.
INTERACTIVE
      INSTRUCTION="Read $TASK_FILE and execute the complete review. Create $AGENT_REPORT as instructed."
      if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$INSTRUCTION" | pbcopy
      fi
      "$IDFC_CODER_CMD" 2>&1 | tee "$AGENT_LOG"
      ;;
  esac
}

run_agent

if [[ -f "$AGENT_REPORT" ]]; then
  cp "$AGENT_REPORT" "$FINAL_REPORT"
  cp "$AGENT_LOG" "$FINAL_LOG"
  echo
  echo "Review complete."
  echo "Report: $FINAL_REPORT"
  echo "Agent log: $FINAL_LOG"
else
  echo
  echo "WARNING: idfc-coder exited but the reviewer report was not created: $AGENT_REPORT" >&2
  echo "Worktree: $WORKTREE" >&2
  echo "Review data: $REVIEW_DIR" >&2
  echo "Agent log: $FINAL_LOG" >&2
  echo "Use --keep-worktree if you want to inspect the checked-out source after exit." >&2
  exit 3
fi
