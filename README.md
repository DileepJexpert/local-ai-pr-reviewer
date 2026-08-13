# Local AI PR Reviewer

This package runs independently of any existing Bitbucket PR hook. It creates an isolated Git worktree for the PR source branch and lets the internal `idfc-coder` review the complete repository with the PR diff and architecture rules.

## Windows POC: structured JSON and one HTML report

For the Windows workflow, use the PowerShell runner. It creates a unique review folder outside the source repository containing `review.html`, `findings.json`, `review.log`, `codex-output.log`, `pr.diff`, `metadata.json`, the prepared task, and its review rules.

```powershell
.\review-pr.ps1 `
  -Repo 'C:\work\service' `
  -Source 'feature/ABC-123' `
  -Target 'develop' `
  -Pr '1287' `
  -CoderMode stdin `
  -CoderCommand 'idfc-coder' `
  -OpenReport
```

By default the folders are created under `%USERPROFILE%\AI-PR-Reviews`; use `-OutputRoot` to choose another user-controlled location. The runner uses local branches when `origin` does not exist and fetches `origin` only when configured. `-CoderCommand` is one executable command/path, never a shell command string; use a trusted wrapper for fixed arguments.

## 1. Copy this folder to your Mac

Example:

```bash
mkdir -p ~/tools/local-ai-pr-reviewer
cp -R local-ai-pr-reviewer/* ~/tools/local-ai-pr-reviewer/
cd ~/tools/local-ai-pr-reviewer
chmod +x review-pr.sh
```

## 2. Review the current branch against develop

```bash
./review-pr.sh \
  --repo /path/to/your/local/repository \
  --target develop
```

## 3. Review another developer's source branch

```bash
./review-pr.sh \
  --repo /path/to/your/local/repository \
  --source feature/consumer-request-lookup \
  --target develop \
  --pr 1234
```

The script runs `git fetch --prune origin`, creates a temporary detached worktree at the source ref, and calculates the PR change using the merge base.

## 4. idfc-coder invocation mode

Because `idfc-coder` is an internal command and its non-interactive flags are not known here, the default is safe interactive mode:

```bash
IDFC_CODER_MODE=interactive ./review-pr.sh --repo /repo --source feature/x --target develop
```

The script opens `idfc-coder` from the PR worktree, displays the reviewer-controlled task path, and copies an instruction using that path to the macOS clipboard:

```text
Read the displayed review task path and execute the complete review. Create the output report path specified in that task.
```

Paste it into the agent and run the review.

If your `idfc-coder` accepts prompts on stdin, you can make the whole run non-interactive:

```bash
IDFC_CODER_MODE=stdin ./review-pr.sh --repo /repo --source feature/x --target develop
```

If it accepts a prompt as a positional argument:

```bash
IDFC_CODER_MODE=arg ./review-pr.sh --repo /repo --source feature/x --target develop
```

If your CLI command is not literally `idfc-coder`, override it with a single executable name or executable path. For commands that require fixed arguments, use a trusted wrapper script as the executable:

```bash
IDFC_CODER_CMD='/path/to/your-idfc-coder-wrapper' IDFC_CODER_MODE=stdin ./review-pr.sh ...
```

`IDFC_CODER_CMD` is never evaluated as shell code; shell operators and inline arguments are intentionally rejected.

## 5. Output

Reports are copied back into the original repository under:

```text
.ai-review-reports/
```

Example:

```text
.ai-review-reports/pr-1234-feature_consumer-request-lookup-20260812-151500.md
```

The raw agent console output is also stored beside it as `.agent.log`. Reviewer rules, diffs, prompts, temporary output, and the agent's initial report are stored outside the checked-out PR worktree.

## 6. Keep the temporary worktree for debugging

```bash
./review-pr.sh --repo /repo --source feature/x --target develop --keep-worktree
```

This also keeps the separate reviewer-data directory and prints its path, so the generated task, rules, diffs, and agent output remain available without writing them into the PR checkout.

## Design

The review deliberately has four layers:

1. baseline review,
2. technology-specific review activated by change impact,
3. execution-path/failure-mode analysis,
4. open-ended novel-risk discovery.

There is no fixed cap on BLOCKER/MAJOR findings. Equivalent findings are deduplicated instead of suppressed.
