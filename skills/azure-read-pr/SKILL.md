---
name: azure-read-pr
description: Read Azure DevOps pull requests and changed code via az CLI
user-invocable: false
when_to_use: |
  Use this skill when:
  - Finding pull requests related to a work item
  - Reading PR metadata (status, branches, reviewers, linked work items)
  - Listing PR commits and changed files
  - Reading changed code from PR commits without local git
  - Building an implementation plan based on historical PRs
---

# Azure PR Skill

Run `get-pr.ps1` (located alongside this skill file) to fetch everything in one call: metadata, changed files, line-level diffs, and comment threads. The result is written to a file in the current working directory for reliable reading with `read_file`.

## Available scripts

- **`scripts/get-pr.ps1`** — Get PR metadata, changed files, line-level diffs, and comment threads in one run; variables left in scope for follow-up commands

## Reading Full PR 

Run with a PR ID:

```powershell
scripts\get-pr.ps1 -PrId <id>
```

Or discover the PR from a work item:

```powershell
scripts\get-pr.ps1 -WorkItemId <id>
```

The script writes the result to `get-pr-<id>-output.txt` in the **current working directory** (i.e. the workspace root) and prints `PR output written to: <path>`. Use `read_file` on that path to read the full result — this avoids terminal buffer truncation for large PRs, lets you page through the output with line ranges, and requires no permission prompt since the file lands inside the open workspace.

## Read File Content at a Specific Commit

When you need actual source lines for context around a diff hunk, re-derive the shared variables from the PR id and then fetch file content:

```powershell
$pr      = az repos pr show --id <id> --output json | ConvertFrom-Json
$repoId  = $pr.repository.id
$project = $pr.repository.project.name
$target  = $pr.lastMergeSourceCommit.commitId
$org     = (az devops configure --list 2>&1 | Select-String 'organization\s*=\s*(.+)').Matches[0].Groups[1].Value.Trim().TrimEnd('/')
$token   = (az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" --output json | ConvertFrom-Json).accessToken
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl = "$org/$([Uri]::EscapeDataString($project))/_apis/git/repositories/$repoId"

$encoded = [Uri]::EscapeDataString("{repo_path}")
$file    = Invoke-RestMethod -Uri "$baseUrl/items?path=$encoded&versionDescriptor.version=$target&versionDescriptor.versionType=commit&includeContent=true&api-version=7.1" -Headers $headers
$lines   = $file.content -split "`n"
# e.g. 5 lines of context around line 300:
$lines[294..304] | ForEach-Object -Begin {$i=295} -Process {"$i`: $_"; $i++}
```

## Gotchas

- Always quote project names with spaces: `project="$project"` — bare `project=$project` splits on spaces and crashes the CLI
- `fileDiffs` only accepts `baseVersionCommit`/`targetVersionCommit` as flat strings, **not** descriptor objects
- `fileDiffs` throws HTTP 500 for added or deleted files — always filter to `changeType -eq 'edit'` before posting
- `fileDiffs` accepts at most 10 files per request — the script batches automatically in chunks of 10; if you call it manually, chunk your `fileDiffParams` array
- Use `Invoke-RestMethod` for POST calls — `az devops invoke --in-file` requires a real file path on Windows
- AAD resource ID `499b84ac-1321-427f-aa17-267ca6975798` is the Azure DevOps resource for `az account get-access-token`
- On encoding issues, run `chcp 65001` first
- The full script block may silently truncate `$changedFiles` if the `az devops invoke` output is large; the output section will show `Edited (0)` / `Added (0)` as a symptom. If this happens, re-run the script
- **Never use `Write-Host` for output** — it writes to PowerShell's information stream (stream 6) which is not captured by the terminal tool; use bare string expressions instead (e.g. `"$($var)"` not `Write-Host "$($var)"`)
- **Collect all output into `$out` and emit with `$out -join "`n"`** — the terminal tool takes an output snapshot when the terminal goes idle; a script that does heavy network I/O and then prints many lines can have output arrive *after* the snapshot. Collecting everything first and emitting as a single string guarantees one flush at the very end

