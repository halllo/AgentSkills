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

Paste the single script block below into the terminal. It loads everything in one run: metadata, changed files, line-level diffs, and comment threads. Set either `$prId` or `$workItemId` at the top.

## Prerequisites

Azure DevOps defaults must be configured:

```bash
az devops configure --defaults organization=https://dev.azure.com/{org} project="{project}"
```

## Full PR Load Script

```powershell
& {
$prId       = 0   # set PR ID directly — OR —
$workItemId = 0   # set work item ID to discover PR from linked relations

# Discover PR from work item if needed
if (-not $prId -and $workItemId) {
    $wi    = az boards work-item show --id $workItemId --expand relations --output json | ConvertFrom-Json
    $prUrl = $wi.relations | Where-Object { $_.rel -eq 'ArtifactLink' -and $_.url -like '*PullRequestId*' } | Select-Object -First 1 -ExpandProperty url
    if (-not $prUrl) { throw "No linked PR found on work item $workItemId" }
    $prId  = [int]($prUrl -split '%2f')[-1]
}

# Metadata + shared context
$pr      = az repos pr show --id $prId --output json | ConvertFrom-Json
$repoId  = $pr.repository.id
$project = $pr.repository.project.name
$base    = $pr.lastMergeTargetCommit.commitId
$target  = $pr.lastMergeSourceCommit.commitId
$org     = (az devops configure --list 2>&1 | Select-String 'organization\s*=\s*(.+)').Matches[0].Groups[1].Value.Trim().TrimEnd('/')
$token   = (az account get-access-token --resource "499b84ac-1321-427f-aa17-267ca6975798" --output json | ConvertFrom-Json).accessToken
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
$baseUrl = "$org/$([Uri]::EscapeDataString($project))/_apis/git/repositories/$repoId"

# Changed files
$changedFiles = az devops invoke --area git --resource commitDiffs `
    --route-parameters project="$project" repositoryId=$repoId `
    --query-parameters "baseVersion=$base" "baseVersionType=commit" "targetVersion=$target" "targetVersionType=commit" `
    --api-version 7.1 --output json | ConvertFrom-Json |
    Select-Object -ExpandProperty changes | Where-Object { $_.item.gitObjectType -eq "blob" }
$editedFiles  = $changedFiles | Where-Object { $_.changeType -eq 'edit' }
$addedFiles   = $changedFiles | Where-Object { $_.changeType -eq 'add' }
$deletedFiles = $changedFiles | Where-Object { $_.changeType -eq 'delete' }

# Line-level diffs — edited files only (add/delete cannot be diffed this way)
$diffBody = @{
    fileDiffParams      = @($editedFiles | ForEach-Object { @{ path = $_.item.path; originalPath = $_.item.path } })
    baseVersionCommit   = $base
    targetVersionCommit = $target
} | ConvertTo-Json -Depth 5
$diffs = Invoke-RestMethod -Uri "$baseUrl/fileDiffs?api-version=7.1" -Method POST -Headers $headers -Body $diffBody

# Comment threads
$threads = Invoke-RestMethod -Uri "$baseUrl/pullRequests/$prId/threads?api-version=7.1" -Method GET -Headers $headers

# Output — collect into $out array and emit as a single joined string so the terminal tool captures
# everything in one flush after all network calls are complete (avoids snapshot timing issues)
$out = @()
$out += "=== PR ${prId}: $($pr.title) ==="
$out += "Status:    $($pr.status)"
$out += "Source:    $($pr.sourceRefName)"
$out += "Target:    $($pr.targetRefName)"
$out += "Reviewers: $($pr.reviewers.displayName -join ', ')"
$out += "WorkItems: $($pr.workItemRefs.id -join ', ')"
$out += ""
$out += "=== Changed Files ==="
$out += "Added ($($addedFiles.Count)):   $(($addedFiles | ForEach-Object { $_.item.path }) -join ', ')"
$out += "Deleted ($($deletedFiles.Count)): $(($deletedFiles | ForEach-Object { $_.item.path }) -join ', ')"
$out += "Edited ($($editedFiles.Count)):"
foreach ($d in $diffs.value) {
    $out += "  $($d.path)"
    foreach ($b in ($d.lineDiffBlocks | Where-Object { $_.changeType -ne 'none' })) {
        $out += "    [$($b.changeType)] orig L$($b.originalLineNumberStart)+$($b.originalLinesCount) -> mod L$($b.modifiedLineNumberStart)+$($b.modifiedLinesCount)"
    }
}
$out += ""
$out += "=== Comment Threads ($($threads.value.Count)) ==="
foreach ($t in ($threads.value | Where-Object { $_.comments.Count -gt 0 })) {
    $loc = if ($t.threadContext.filePath) { "$($t.threadContext.filePath):$($t.threadContext.rightFileStart.line)" } else { "(general)" }
    $out += "  [$($t.status)] $loc"
    $out += "    $($t.comments[0].content)"
}
$out -join "`n"
}
```


## Read File Content at a Specific Commit

When you need actual source lines for context around a diff hunk.

> **Note:** The variables `$repoId`, `$project`, and `$target` are scoped inside the `& { ... }` block above and won't be available afterwards. Re-set them first:

```powershell
$prId    = 0   # same PR ID used above
$pr      = az repos pr show --id $prId --output json | ConvertFrom-Json
$repoId  = $pr.repository.id
$project = $pr.repository.project.name
$target  = $pr.lastMergeSourceCommit.commitId
```

Then fetch the file content:

```powershell
$file = az devops invoke --area git --resource items `
    --route-parameters project="$project" repositoryId=$repoId `
    --query-parameters "path={repo_path}" "versionDescriptor.version=$target" "versionDescriptor.versionType=commit" "includeContent=true" `
    --api-version 7.1 --output json 2>&1 | ConvertFrom-Json

$lines = $file.content -split "`n"
# e.g. 5 lines of context around line 300:
$lines[294..304] | ForEach-Object -Begin {$i=295} -Process {"$i`: $_"; $i++}
```

## Gotchas

- Always quote project names with spaces: `project="$project"` — bare `project=$project` splits on spaces and crashes the CLI
- `fileDiffs` only accepts `baseVersionCommit`/`targetVersionCommit` as flat strings, **not** descriptor objects
- `fileDiffs` throws HTTP 500 for added or deleted files — always filter to `changeType -eq 'edit'` before posting
- Use `Invoke-RestMethod` for POST calls — `az devops invoke --in-file` requires a real file path on Windows
- AAD resource ID `499b84ac-1321-427f-aa17-267ca6975798` is the Azure DevOps resource for `az account get-access-token`
- On encoding issues, run `chcp 65001` first
- The full script block may silently truncate `$changedFiles` if the `az devops invoke` output is large; the output section will show `Edited (0)` / `Added (0)` as a symptom. If this happens, re-run the entire `& { ... }` block
- **Never use `Write-Host` for output** — it writes to PowerShell's information stream (stream 6) which is not captured by the terminal tool; use bare string expressions instead (e.g. `"$($var)"` not `Write-Host "$($var)"`)
- **Collect all output into `$out` and emit with `$out -join "`n"`** — the terminal tool takes an output snapshot when the terminal goes idle; a script that does heavy network I/O and then prints many lines can have output arrive *after* the snapshot. Collecting everything first and emitting as a single string guarantees one flush at the very end
- **Wrap the entire script in `& { ... }`** — when a large script block is pasted into the terminal, PowerShell can briefly go idle between accepting the input and starting execution of the first network call. The terminal tool mistakes this transient idle for completion and returns an empty snapshot. Wrapping in `& { ... }` ensures the terminal only becomes idle once — after the entire script block has finished

