# Local AI PR Reviewer

This package runs independently of any existing Bitbucket PR hook. It creates an isolated Git worktree for the PR source branch and lets the internal `idfc-coder` review the complete repository with the PR diff and architecture rules.

## Review accuracy safeguard

The reviewer now uses a mandatory evidence pipeline:

```text
PR diff → change classification → execution-path discovery → initial review
→ candidate findings → counter-evidence verification → final judge → report
```

BLOCKER and MAJOR findings are candidates until a separate disproof pass inspects the relevant callers, callees, helpers, transactions, JPA lifecycle, locks, constraints, configuration, and tests. A candidate that is disproved is marked `REJECTED` and cannot appear in final PR findings. The JSON report records candidate verification, and the local validator rejects a final BLOCKER/MAJOR that lacks execution-path, counter-evidence, PR-attribution, and confirmed-verification fields.

Run reviewer-level regression fixtures on Windows:

```powershell
.\tests\review-verification-test.ps1
```

The fixtures cover helper-based state synchronization, upstream pessimistic locking, an unprotected race, a pre-existing observation, and a helper that does not mitigate the issue.

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

By default all reports are created inside this project at `reviews\`; use `-OutputRoot` to choose another folder. The runner uses local branches when `origin` does not exist and fetches `origin` only when configured. `-CoderCommand` is one executable command/path, never a shell command string; use a trusted wrapper for fixed arguments.

### Review modes

`-ReviewMode guided` is the existing single-review behaviour: it uses the neutral review instruction plus the existing custom rules. `-ReviewMode baseline` uses the same neutral instruction and output schema, but does not load or inject custom rules. `-ReviewMode both` prepares the PR once, freezes the source SHA, target SHA, merge base, diff, worktree, and model configuration, then runs baseline followed by guided.

For BOTH mode the output folder contains `baseline\` and `guided\` subfolders, each with `findings.json`, `review.html`, `review.log`, and `model-output.log`; the root contains the frozen `pr.diff`, `metadata.json`, and `comparison.html`.

```powershell
.\review-pr.ps1 -Repository 'C:\work\katasticho' -Source 'feature/example' -Target main -Pr example -ReviewMode both -CoderCommand 'idfc-coder' -CoderMode stdin -OpenReport
```

### One command from a GitHub compare URL

Once a compatible local reviewer executable is installed, paste a GitHub compare URL into this command. It extracts the source branch (and target when the URL contains `main...branch`), runs the secure review, generates the report, and opens it.

```powershell
.\start-review.ps1 -Repository 'C:\work\katasticho' -PrUrl 'https://github.com/DileepJexpert/katasticho/compare/codex/contact-roles-field-sales-planning?expand=1' -Target main -CoderCommand 'idfc-coder' -OpenReport
```

Or run `review.cmd` from this folder and paste the URL and repository path when asked. Reports will appear in `reviews\` beside the scripts.

If double-clicking `review.cmd` opens an editor on Windows, double-click `Review PR.vbs` instead. It opens a Command Prompt and runs the same guided review.

### macOS

Copy the folder to your Mac once, then make the launch files executable:

```bash
cd ~/tools/local-ai-pr-reviewer
chmod +x review.command start-review.sh review-pr.sh
```

Double-click `review.command` in Finder, or run `./review.command` in Terminal. Paste the GitHub compare URL, local cloned repository path, and your installed `idfc-coder` command. Reports are written to `reviews/` inside this reviewer folder.

The optional Flutter Windows UI is in `reviewer_launcher`. It runs this same command after you paste a URL. It needs a callable local reviewer executable such as `idfc-coder` or a trusted wrapper which reads the task from standard input and writes the requested `findings.json`.

To test with Codex desktop before `idfc-coder` is installed, prepare the isolated review context without launching an agent:

```powershell
.\review-pr.ps1 `
  -Repo 'C:\work\service' `
  -Source 'feature/ABC-123' `
  -Target 'main' `
  -Pr '1287' `
  -PrepareOnly
```

The command prints a temporary worktree, a reviewer-controlled `REVIEW_TASK.md`, and the required `findings.json` output path. Open the worktree in Codex desktop and ask Codex to read that task and create the JSON at the printed output path. Then generate the report:

```powershell
.\generate-report.ps1 -FindingsPath 'C:\Users\<you>\AI-PR-Reviews\PR-1287-...\findings.json' -OutputPath 'C:\Users\<you>\AI-PR-Reviews\PR-1287-...\review.html'
```

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

The review deliberately uses a bias-resistant sequence:

1. neutral repository and architecture discovery from ADRs, the current module, comparable modules, and history;
2. blind/open-ended defect hypotheses;
3. technology and organisation-rule compliance hypotheses;
4. counter-evidence/disproof followed by a final judge and open-ended novel-risk pass.

The reviewer does not assume a named architecture is preferred. Architecture drift is reported separately from correctness only when repository evidence shows an unintentional inconsistency. Candidate hypotheses contain no recommendation; a fix is allowed only after counter-evidence verification, including a prompt-bias self-check that rejects pattern-driven claims without independent repository evidence.

There is no fixed cap on BLOCKER/MAJOR findings. Equivalent findings are deduplicated instead of suppressed.
