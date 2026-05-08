---
name: azure-create-pr
description: Push a feature branch and create an Azure DevOps pull request via az CLI
user-invocable: false
when_to_use: |
  Use this skill when:
  - Creating a new pull request from the current branch
  - Pushing a local feature branch and opening a PR against a target branch
---

# Azure Create PR Skill

## Prerequisites

Azure DevOps defaults must be configured:

```bash
az devops configure --defaults organization=https://dev.azure.com/{org} project="{project}"
```

Git must be installed and the working directory must be inside the target repo.

## Full Create PR Script

Paste the block below into the terminal. Set the variables at the top, then run.

```powershell
& {
$targetBranch = "main"         # The branch the PR merges INTO (e.g. "main" or "dev")
$prTitle      = ""             # PR title — leave empty to auto-generate from branch name
$prDescription = ""            # PR description body (optional)
$workItemId   = 0              # Work item to link (0 = skip)
$draft        = $true          # Set to $false to publish immediately

# --- 1. Guard: must not be on main or dev ---
$currentBranch = git rev-parse --abbrev-ref HEAD 2>&1
if ($LASTEXITCODE -ne 0) { throw "Not inside a git repository." }
if ($currentBranch -in @("main", "master", "dev", "develop")) {
    throw "You are on '$currentBranch'. Switch to a feature branch before creating a PR."
}

# --- 2. Check for uncommitted changes ---
$status = git status --porcelain 2>&1
if ($status) {
    Write-Warning "Uncommitted changes detected. Stash or commit them before pushing."
    $status
    throw "Aborted: uncommitted changes present."
}

# --- 3. Push branch to remote ---
"Pushing branch '$currentBranch' to origin..."
git push --set-upstream origin $currentBranch
if ($LASTEXITCODE -ne 0) { throw "git push failed." }

# --- 4. Build PR title ---
if (-not $prTitle) {
    # Convert branch name to a readable title: feature/my-cool-thing -> My cool thing
    $prTitle = ($currentBranch -replace '^(feature|fix|chore|hotfix|release)/', '') -replace '[-_]', ' '
    $prTitle = (Get-Culture).TextInfo.ToTitleCase($prTitle.ToLower())
}
# Prepend work item number if provided
if ($workItemId -gt 0) {
    $prTitle = "#${workItemId}: $prTitle"
}

# --- 5. Create the PR via az CLI ---
$azArgs = @(
    "repos", "pr", "create",
    "--source-branch", $currentBranch,
    "--target-branch", $targetBranch,
    "--title", $prTitle,
    "--output", "json"
)
if ($prDescription)  { $azArgs += "--description", $prDescription }
if ($draft)          { $azArgs += "--draft" }
if ($workItemId -gt 0) { $azArgs += "--work-items", "$workItemId" }

$pr = az @azArgs | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "az repos pr create failed." }

# --- 6. Output summary ---
$out = @()
$out += "=== PR Created ==="
$out += "ID:     $($pr.pullRequestId)"
$out += "Title:  $($pr.title)"
$out += "Source: $($pr.sourceRefName)"
$out += "Target: $($pr.targetRefName)"
$out += "Status: $($pr.status)"
$out += "URL:    $($pr.url -replace '_apis/git/repositories/.+/pullRequests', '_git/' + $pr.repository.name + '/pullrequest')"
if ($workItemId -gt 0) { $out += "Linked work item: $workItemId" }
$out -join "`n"
}
```

## Gotchas

- Always run from a feature branch — the script aborts on `main`, `master`, `dev`, or `develop`
- Stash or commit all changes before running; the script aborts if the working tree is dirty
- `--set-upstream` is used so future `git push` works without specifying the remote
- The pretty PR URL is constructed manually; `$pr.url` is an API URL, not a browser URL
- If the branch already exists on the remote (e.g. after a force-push), `git push` will still succeed
- For repos with branch policies, the PR may be created but immediately marked as draft or blocked — check `$pr.status`
- Always quote `--title` and `--description` values to handle spaces; the `$azArgs` array approach handles this automatically
- Re-running the script after a successful push will fail on `git push` with "Everything up-to-date" (exit 0) and then fail on `az repos pr create` if a PR already exists for that branch — check for an existing PR first if needed
