param(
    [Parameter(Mandatory=$true)][string]$RootB64,
    [Parameter(Mandatory=$true)][string]$WorkDirB64,
    [Parameter(Mandatory=$true)][string]$IncludeB64,
    [Parameter(Mandatory=$true)][string]$ExcludeB64,
    [Parameter(Mandatory=$true)][string]$ProgressB64,
    [Parameter(Mandatory=$true)][string]$CancelB64,
    [Parameter(Mandatory=$true)][string]$ErrorB64
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Decode-Text([string]$value) {
    return [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($value))
}

function Write-ProgressAtomic($value) {
    $tmp = $progressPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    [System.IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $value -Depth 8), [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($progressPath)) {
        try { [System.IO.File]::Replace($tmp, $progressPath, $null) } catch { Move-Item -LiteralPath $tmp -Destination $progressPath -Force }
    } else { [System.IO.File]::Move($tmp, $progressPath) }
}

function Get-PatternList([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return @($value -split '[;\r\n]+' | ForEach-Object { $_.Trim().Replace('/', '\') } | Where-Object { $_.Length -gt 0 })
}

function Test-Pattern([string]$relativePath, [string[]]$patterns) {
    if (-not $patterns -or $patterns.Count -eq 0) { return $false }
    $relativePath = $relativePath.Replace('/', '\').TrimStart('\')
    $segments = @($relativePath -split '\\')
    foreach ($pattern in $patterns) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        $wp = [System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase)
        if ($wp.IsMatch($relativePath)) { return $true }
        if ($pattern.IndexOf('\') -lt 0) {
            foreach ($segment in $segments) { if ($wp.IsMatch($segment)) { return $true } }
        }
    }
    return $false
}

function Test-SelectedPath([string]$fullPath, [string]$root, [string[]]$includes, [string[]]$excludes) {
    $relative = $fullPath.Substring($root.TrimEnd('\').Length).TrimStart('\')
    if ($includes.Count -gt 0 -and -not (Test-Pattern $relative $includes)) { return $false }
    return -not (Test-Pattern $relative $excludes)
}

function Test-ExcludedDirectory([string]$fullPath, [string]$root, [string[]]$excludes) {
    $relative = $fullPath.Substring($root.TrimEnd('\').Length).TrimStart('\')
    if (Test-Pattern $relative $excludes) { return $true }
    return (Test-Pattern ($relative + '\__bookforge_directory_marker__') $excludes)
}

function Write-ErrorText([string]$text) {
    try { [System.IO.File]::WriteAllText($errorPath, $text, [System.Text.UTF8Encoding]::new($false)) } catch {}
}

try {
    $rootFull = [System.IO.Path]::GetFullPath((Decode-Text $RootB64))
    $rootDrive = [System.IO.Path]::GetPathRoot($rootFull)
    if ($rootFull.TrimEnd('\').Equals($rootDrive.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { $root = $rootDrive } else { $root = $rootFull.TrimEnd('\') }
    $workDir = Decode-Text $WorkDirB64
    $includes = Get-PatternList (Decode-Text $IncludeB64)
    $excludes = Get-PatternList (Decode-Text $ExcludeB64)
    $progressPath = Decode-Text $ProgressB64
    $cancelPath = Decode-Text $CancelB64
    $errorPath = Decode-Text $ErrorB64
    $reportPath = Join-Path $workDir 'duplicates.csv'
    $summaryPath = Join-Path $workDir 'summary.json'
    $startedAt = (Get-Date).ToString('o')
    $progress = [pscustomobject]@{ Status = 'Running'; Phase = 'Scanning'; Root = $root; StartedAt = $startedAt; CompletedAt = ''; ReportCreatedAt = ''; EntriesScanned = 0; FilesScanned = 0; TotalFiles = 0; HashedFiles = 0; CandidateFiles = 0; DuplicateGroups = 0; DuplicateFiles = 0; RedundantCopies = 0; PotentialSavings = [long]0; Warnings = 0; ReportPath = $reportPath; Updated = $startedAt }
    Write-ProgressAtomic $progress
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    $files = [System.Collections.Generic.List[object]]::new()
    $lastUpdate = [DateTime]::MinValue
    while ($stack.Count -gt 0) {
        if (Test-Path -LiteralPath $cancelPath -PathType Leaf) { $progress.Status = 'Cancelled'; $progress.Phase = 'Cancelled'; $progress.FilesScanned = $files.Count; $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress; exit 0 }
        $directory = $stack.Pop()
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($directory, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
                $progress.EntriesScanned++
                if (([System.IO.Path]::GetExtension($file)).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)) {
                    try { if (([System.IO.File]::GetAttributes($file) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue } } catch { $progress.Warnings++; continue }
                    if (Test-SelectedPath $file $root $includes $excludes) {
                        try { $info = [System.IO.FileInfo]::new($file); $files.Add([pscustomobject]@{ Path = $file; Length = [long]$info.Length }) }
                        catch { $progress.Warnings++ }
                    }
                }
                if ((([System.IO.Path]::GetExtension($file)).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase))) { $progress.FilesScanned++ }
                if (((Get-Date) - $lastUpdate).TotalSeconds -ge 1) { $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress; $lastUpdate = Get-Date }
                if (Test-Path -LiteralPath $cancelPath -PathType Leaf) { $progress.Status = 'Cancelled'; $progress.Phase = 'Cancelled'; $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress; exit 0 }
            }
        } catch { $progress.Warnings++ }
        try {
            foreach ($subdir in [System.IO.Directory]::EnumerateDirectories($directory, '*', [System.IO.SearchOption]::TopDirectoryOnly)) {
                $progress.EntriesScanned++
                try {
                    $attributes = [System.IO.File]::GetAttributes($subdir)
                    if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    if (-not (Test-ExcludedDirectory $subdir $root $excludes)) { $stack.Push($subdir) }
                } catch { $progress.Warnings++ }
            }
        } catch { $progress.Warnings++ }
    }
    $progress.TotalFiles = $files.Count
    $progress.FilesScanned = $files.Count
    $progress.Phase = 'Hashing'
    $sizeGroups = @($files | Group-Object Length | Where-Object { $_.Count -gt 1 })
    $progress.CandidateFiles = [int](($sizeGroups | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum)
    $progress.TotalFiles = [Math]::Max(1, $progress.CandidateFiles)
    Write-ProgressAtomic $progress
    $hashGroups = [System.Collections.Generic.List[object]]::new()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($sizeGroup in $sizeGroups) {
            foreach ($item in $sizeGroup.Group) {
                if (Test-Path -LiteralPath $cancelPath -PathType Leaf) { $progress.Status = 'Cancelled'; $progress.Phase = 'Cancelled'; $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress; exit 0 }
                $stream = $null
                try {
                    $stream = [System.IO.File]::Open($item.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                    $hash = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
                    $hashGroups.Add([pscustomobject]@{ Path = $item.Path; Length = [long]$item.Length; Hash = $hash })
                } catch { $progress.Warnings++ }
                finally { if ($stream) { $stream.Dispose() } }
                $progress.HashedFiles++
                if (($progress.HashedFiles % 10) -eq 0 -or ((Get-Date) - $lastUpdate).TotalSeconds -ge 1) { $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress; $lastUpdate = Get-Date }
            }
        }
    } finally { $sha.Dispose() }
    $duplicates = @($hashGroups | Group-Object { "$($_.Length):$($_.Hash)" } | Where-Object { $_.Count -gt 1 })
    $reportCreatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $csvWriter = [System.IO.StreamWriter]::new($reportPath, $false, [System.Text.UTF8Encoding]::new($true))
    try {
        $csvWriter.WriteLine('FechaHoraInforme,Grupo,BytesPorArchivo,Copias,CopiasRedundantes,AhorroPotencialDelGrupoBytes,SHA256,Ruta')
        $groupNumber = 0
        foreach ($group in $duplicates) {
            $groupNumber++
            $items = @($group.Group | Sort-Object Path)
            $length = [long]$items[0].Length
            $redundant = $items.Count - 1
            $savings = [long]($length * $redundant)
            $progress.DuplicateGroups++
            $progress.DuplicateFiles += $items.Count
            $progress.RedundantCopies += $redundant
            $progress.PotentialSavings += $savings
            foreach ($item in $items) {
                $values = @($reportCreatedAt, $groupNumber, $length, $items.Count, $redundant, $savings, $item.Hash, $item.Path)
                $escaped = foreach ($value in $values) { '"' + ([string]$value).Replace('"', '""') + '"' }
                $csvWriter.WriteLine(($escaped -join ','))
            }
        }
    } finally { $csvWriter.Dispose() }
    $progress.Status = 'Completed'
    $progress.Phase = 'Completed'
    $progress.ReportPath = $reportPath
    $progress.ReportCreatedAt = $reportCreatedAt
    $progress.CompletedAt = (Get-Date).ToString('o')
    $progress.Updated = $progress.CompletedAt
    Write-ProgressAtomic $progress
    [System.IO.File]::WriteAllText($summaryPath, (ConvertTo-Json -InputObject $progress -Depth 8), [System.Text.UTF8Encoding]::new($false))
    exit 0
} catch {
    Write-ErrorText $_.Exception.ToString()
    try { $progress.Status = 'Error'; $progress.Phase = 'Error'; $progress.Updated = (Get-Date).ToString('o'); Write-ProgressAtomic $progress } catch {}
    exit 1
}
