param(
    [int]$PrId       = 0,   # set PR ID directly — OR —
    [int]$WorkItemId = 0    # set work item ID to discover PR from linked relations
)

# Discover PR from work item if needed
if (-not $PrId -and $WorkItemId) {
    $wi    = az boards work-item show --id $WorkItemId --expand relations --output json | ConvertFrom-Json
    $prUrl = $wi.relations | Where-Object { $_.rel -eq 'ArtifactLink' -and $_.url -like '*PullRequestId*' } | Select-Object -First 1 -ExpandProperty url
    if (-not $prUrl) { throw "No linked PR found on work item $WorkItemId" }
    $PrId  = [int]($prUrl -split '%2f')[-1]
}

# Metadata + shared context
$pr      = az repos pr show --id $PrId --output json | ConvertFrom-Json
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
# The API accepts at most 10 files per request, so batch in chunks of 10
$allDiffValues = @()
$editedFileParams = @($editedFiles | ForEach-Object { @{ path = $_.item.path; originalPath = $_.item.path } })
for ($i = 0; $i -lt $editedFileParams.Count; $i += 10) {
    $chunk = $editedFileParams[$i..([Math]::Min($i + 9, $editedFileParams.Count - 1))]
    $diffBody = @{
        fileDiffParams      = $chunk
        baseVersionCommit   = $base
        targetVersionCommit = $target
    } | ConvertTo-Json -Depth 5
    $chunkDiffs = Invoke-RestMethod -Uri "$baseUrl/fileDiffs?api-version=7.1" -Method POST -Headers $headers -Body $diffBody
    $allDiffValues += $chunkDiffs.value
}
$diffs = [PSCustomObject]@{ value = $allDiffValues }

# Comment threads
$threads = Invoke-RestMethod -Uri "$baseUrl/pullRequests/$PrId/threads?api-version=7.1" -Method GET -Headers $headers

# Helper: fetch file content as a line array at a given commit
function Get-FileLines {
    param([string]$Path, [string]$CommitId)
    $encoded = [Uri]::EscapeDataString($Path)
    $content = Invoke-RestMethod -Uri "$baseUrl/items?path=$encoded&versionDescriptor.version=$CommitId&versionDescriptor.versionType=commit&includeContent=true&api-version=7.1" -Headers $headers -ErrorAction SilentlyContinue
    if ($content) { return ($content -split "`n") }
    return @()
}

# Output — collect into $out array and emit as a single joined string so the terminal tool captures
# everything in one flush after all network calls are complete (avoids snapshot timing issues)
$out = @()
$out += "=== PR ${PrId}: $($pr.title) ==="
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
    $changedBlocks = @($d.lineDiffBlocks | Where-Object { $_.changeType -ne 'none' })
    $out += "--- a$($d.path)"
    $out += "+++ b$($d.path)"
    if (-not $changedBlocks) { continue }
    $origLines = Get-FileLines -Path $d.path -CommitId $base
    $modLines  = Get-FileLines -Path $d.path -CommitId $target
    foreach ($b in $changedBlocks) {
        $out += "@@ -$($b.originalLineNumberStart),$($b.originalLinesCount) +$($b.modifiedLineNumberStart),$($b.modifiedLinesCount) @@"
        for ($i = $b.originalLineNumberStart - 1; $i -lt $b.originalLineNumberStart - 1 + $b.originalLinesCount; $i++) {
            $out += "-$($origLines[$i])"
        }
        for ($i = $b.modifiedLineNumberStart - 1; $i -lt $b.modifiedLineNumberStart - 1 + $b.modifiedLinesCount; $i++) {
            $out += "+$($modLines[$i])"
        }
    }
}
$out += ""
$out += "=== Comment Threads ($($threads.value.Count)) ==="
foreach ($t in ($threads.value | Where-Object { $_.comments.Count -gt 0 })) {
    $loc = if ($t.threadContext.filePath) { "$($t.threadContext.filePath):$($t.threadContext.rightFileStart.line)" } else { "(general)" }
    $out += "  [$($t.status)] $loc"
    $out += "    $($t.comments[0].content)"
}

# Write to a predictable temp file so the agent can read it via read_file without
# relying on terminal buffer capture (which truncates large output)
$prOutputFile = Join-Path (Get-Location) "get-pr-$PrId-output.txt"
$out -join "`n" | Set-Content -Path $prOutputFile -Encoding UTF8
"PR output written to: $prOutputFile"

