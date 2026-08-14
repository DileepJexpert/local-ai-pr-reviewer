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

#### Apple Silicon / M-series quick start

These steps work on an M1, M2, M3, or M4 Mac. Open **Terminal** and first verify your organisation's reviewer command is installed and authenticated:

```bash
idfc-coder --help
```

Clone the reviewer and the application repository. Use `git pull` instead of cloning again on later runs.

```bash
mkdir -p ~/tools ~/work
git clone git@github.com:DileepJexpert/local-ai-pr-reviewer.git ~/tools/local-ai-pr-reviewer
git clone git@github.com:DileepJexpert/katasticho.git ~/work/katasticho
cd ~/tools/local-ai-pr-reviewer
chmod +x review.command start-review.sh review-pr.sh
```

Run the review with one command:

```bash
./start-review.sh \
  --repo "$HOME/work/katasticho" \
  --url 'https://github.com/DileepJexpert/katasticho/compare/codex/contact-roles-field-sales-planning?expand=1' \
  --target main \
  --coder idfc-coder
```

The script supplies the review task to `idfc-coder` through standard input. If your organisation's command requires interactive mode instead, run:

```bash
IDFC_CODER_MODE=interactive ./review-pr.sh \
  --repo "$HOME/work/katasticho" \
  --source 'codex/contact-roles-field-sales-planning' \
  --target main \
  --pr 'contact-roles'
```

The report is saved in `~/tools/local-ai-pr-reviewer/reviews/`. In Finder, open that folder with:

```bash
open "$HOME/tools/local-ai-pr-reviewer/reviews"
```

For later runs, update both repositories:

```bash
cd ~/tools/local-ai-pr-reviewer && git pull origin main
cd ~/work/katasticho && git fetch --prune origin
```

`review.command` is an optional Finder launcher; double-click it and paste the compare URL, repository folder, and `idfc-coder` when prompted.

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

## Design

The review deliberately uses a bias-resistant sequence:

1. neutral repository and architecture discovery from ADRs, the current module, comparable modules, and history;
2. blind/open-ended defect hypotheses;
3. technology and organisation-rule compliance hypotheses;
4. counter-evidence/disproof followed by a final judge and open-ended novel-risk pass.

The reviewer does not assume a named architecture is preferred. Architecture drift is reported separately from correctness only when repository evidence shows an unintentional inconsistency. Candidate hypotheses contain no recommendation; a fix is allowed only after counter-evidence verification, including a prompt-bias self-check that rejects pattern-driven claims without independent repository evidence.

There is no fixed cap on BLOCKER/MAJOR findings. Equivalent findings are deduplicated instead of suppressed.
