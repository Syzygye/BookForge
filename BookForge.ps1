$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

$script:SingleInstanceMutex = $null
$script:SingleInstanceAcquired = $false
try {
    $script:SingleInstanceMutex = [System.Threading.Mutex]::new($false, 'Local\BookForge_1_0')
    try { $script:SingleInstanceAcquired = $script:SingleInstanceMutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $script:SingleInstanceAcquired = $true }
} catch { $script:SingleInstanceAcquired = $true }
if (-not $script:SingleInstanceAcquired) {
    [System.Windows.Forms.MessageBox]::Show('BookForge ya está abierto. Utiliza la ventana que está en ejecución.', 'BookForge', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    if ($script:SingleInstanceMutex) { $script:SingleInstanceMutex.Dispose() }
    exit 0
}

if (-not ('BookForge.PowerPolicy' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BookForge {
    public static class PowerPolicy {
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern uint SetThreadExecutionState(uint flags);
        public static bool KeepAwake(bool enabled) {
            uint value = enabled ? 0x80000001U : 0x80000000U;
            return SetThreadExecutionState(value) != 0;
        }
    }
}
'@
}

$script:AppRoot = Join-Path $env:LOCALAPPDATA 'BookForge'
$script:JobsRoot = Join-Path $script:AppRoot 'Jobs'
$script:ProfilesPath = Join-Path $script:AppRoot 'profiles.json'
$script:PrefsPath = Join-Path $script:AppRoot 'preferences.json'
$script:ConverterPath = $null
$script:RootPath = ''
$script:RootKey = ''
$script:JobDir = ''
$script:ManifestPath = ''
$script:InventoryPath = ''
$script:JournalPath = ''
$script:ReportPath = ''
$script:PreflightReportPath = ''
$script:ErrorLogPath = ''
$script:LoadedErrorLogPath = ''
$script:CurrentPreflightReport = $null
$script:Manifest = $null
$script:JournalWriter = $null
$script:Phase = 'Idle'
$script:RunMode = 'New'
$script:IsRunning = $false
$script:PauseRequested = $false
$script:CloseWhenPaused = $false
$script:ResumeAvailable = $false
$script:Files = [System.Collections.Generic.List[object]]::new()
$script:ScanStack = [System.Collections.Generic.Stack[string]]::new()
$script:FileEnumerator = $null
$script:DirectoryEnumerator = $null
$script:CurrentScanDirectory = ''
$script:ScanMode = 'Files'
$script:DirectoriesSeen = 0
$script:ScanWarnings = 0
$script:ScanEntries = 0
$script:InventoryExisting = 0
$script:InventorySourceBytes = [long]0
$script:InventoryOutputBytes = [long]0
$script:ActiveJobs = [System.Collections.Generic.List[object]]::new()
$script:Index = 0
$script:Total = 0
$script:Converted = 0
$script:Skipped = 0
$script:Failed = 0
$script:FinishedCount = 0
$script:WorkerLimit = 3
$script:LogicalProcessors = [Math]::Max(1, [int][Environment]::ProcessorCount)
$script:RunTimer = [System.Diagnostics.Stopwatch]::new()
$script:ConversionTimer = [System.Diagnostics.Stopwatch]::new()
$script:LastUiUpdate = [DateTime]::MinValue
$script:LastCpuCheck = [DateTime]::MinValue
$script:ElapsedPriorSeconds = 0.0
$script:ConversionPriorSeconds = 0.0
$script:PendingToConvert = 0
$script:LateSkipped = 0
$script:AttemptedCount = 0
$script:ActiveSeconds = 0.0
$script:CpuUsage = -1.0
$script:MemoryUsage = -1.0
$script:JournalRowsSinceFlush = 0
$script:FailedListChanges = 0
$script:CpuCounter = $null
$script:CurrentEta = 'Calculando…'
$script:LastDuplicateReport = ''
$script:DuplicateProcess = $null
$script:DuplicateProgressPath = ''
$script:DuplicateCancelPath = ''
$script:DuplicateWorkDir = ''
$script:DuplicateStartedAt = $null
$script:DuplicateMode = $false
$script:NotificationIcon = $null
$script:PowerAwake = $false
$script:ThemeName = 'Dark'
$script:InventoryAllMatchedInputBytes = [long]0
$script:InventoryAllOutputBytes = [long]0
$script:LastCheckpointAt = [DateTime]::MinValue
$script:DiskPauseTriggered = $false
$script:LastDiskCheck = [DateTime]::MinValue

New-Item -ItemType Directory -Path $script:AppRoot, $script:JobsRoot -Force | Out-Null

function Show-ThemedYesNo([string]$message, [string]$title, [string]$kind = 'Question', [bool]$defaultYes = $false) {
    if (-not $script:Window) {
        $fallback = [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($fallback -eq [System.Windows.Forms.DialogResult]::Yes) { return [System.Windows.MessageBoxResult]::Yes }
        return [System.Windows.MessageBoxResult]::No
    }
    if ($script:ThemeName -eq 'Light') {
        $background = '#F1F5F9'; $panel = '#FFFFFF'; $card = '#F8FAFC'; $foreground = '#0F172A'; $muted = '#64748B'; $border = '#CBD5E1'; $accent = '#2563EB'
    } else {
        $background = '#0F172A'; $panel = '#172033'; $card = '#1E293B'; $foreground = '#F8FAFC'; $muted = '#94A3B8'; $border = '#334155'; $accent = '#3B82F6'
    }
    $dialog = [System.Windows.Window]::new()
    $dialog.Title = $title
    $dialog.Width = 590
    $dialog.MinWidth = 480
    $dialog.MaxWidth = 760
    $dialog.SizeToContent = [System.Windows.SizeToContent]::Height
    $dialog.ResizeMode = [System.Windows.ResizeMode]::NoResize
    $dialog.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterOwner
    $dialog.ShowInTaskbar = $false
    $dialog.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($background)
    $dialog.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($foreground)
    if ($script:Window.IsVisible) { $dialog.Owner = $script:Window }
    $dialog.Tag = if ($defaultYes) { [System.Windows.MessageBoxResult]::Yes } else { [System.Windows.MessageBoxResult]::No }
    $root = [System.Windows.Controls.Grid]::new()
    $root.Margin = [System.Windows.Thickness]::new(18)
    [void]$root.RowDefinitions.Add([System.Windows.Controls.RowDefinition]::new())
    $contentRow = [System.Windows.Controls.RowDefinition]::new(); $contentRow.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star); [void]$root.RowDefinitions.Add($contentRow)
    $buttonRow = [System.Windows.Controls.RowDefinition]::new(); $buttonRow.Height = [System.Windows.GridLength]::Auto; [void]$root.RowDefinitions.Add($buttonRow)
    $heading = [System.Windows.Controls.TextBlock]::new()
    $heading.Text = $title
    $heading.FontSize = 18
    $heading.FontWeight = [System.Windows.FontWeights]::SemiBold
    $heading.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($foreground)
    $heading.Margin = [System.Windows.Thickness]::new(0, 0, 0, 12)
    [void]$root.Children.Add($heading)
    $scroll = [System.Windows.Controls.ScrollViewer]::new()
    $scroll.MaxHeight = 420
    $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $body = [System.Windows.Controls.TextBlock]::new()
    $body.Text = $message
    $body.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $body.Margin = [System.Windows.Thickness]::new(0, 0, 8, 14)
    $body.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($foreground)
    $body.FontSize = 13
    $scroll.Content = $body
    [System.Windows.Controls.Grid]::SetRow($scroll, 1)
    [void]$root.Children.Add($scroll)
    $buttons = [System.Windows.Controls.StackPanel]::new()
    $buttons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $buttons.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $buttons.Margin = [System.Windows.Thickness]::new(0, 10, 0, 0)
    foreach ($choice in @('Yes', 'No')) {
        $button = [System.Windows.Controls.Button]::new()
        $button.Content = if ($choice -eq 'Yes') { 'Sí' } else { 'No' }
        $button.MinWidth = 94
        $button.Margin = [System.Windows.Thickness]::new(5, 0, 0, 0)
        $button.Padding = [System.Windows.Thickness]::new(16, 8, 16, 8)
        $button.BorderThickness = [System.Windows.Thickness]::new(1)
        $button.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($border)
        $button.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($choice -eq 'Yes') { $accent } else { $card }))
        $button.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if ($choice -eq 'Yes') { '#FFFFFF' } else { $foreground }))
        $button.IsDefault = (($choice -eq 'Yes') -and $defaultYes) -or (($choice -eq 'No') -and -not $defaultYes)
        $button.IsCancel = $choice -eq 'No'
        $choiceResult = if ($choice -eq 'Yes') { [System.Windows.MessageBoxResult]::Yes } else { [System.Windows.MessageBoxResult]::No }
        $handler = { $dialog.Tag = $choiceResult; $dialog.DialogResult = $true }.GetNewClosure()
        $button.Add_Click($handler)
        [void]$buttons.Children.Add($button)
    }
    [System.Windows.Controls.Grid]::SetRow($buttons, 2)
    [void]$root.Children.Add($buttons)
    $dialog.Content = $root
    $null = $dialog.ShowDialog()
    return [System.Windows.MessageBoxResult]$dialog.Tag
}

function Find-EbookConvert {
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($base in $bases) {
        foreach ($relative in @('Calibre2\ebook-convert.exe', 'Calibre\ebook-convert.exe', 'Programs\Calibre\ebook-convert.exe', 'Programs\Calibre2\ebook-convert.exe')) {
            $candidate = Join-Path $base $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
        }
    }
    $cmd = Get-Command 'ebook-convert.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Normalize-RootPath([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\').Equals($pathRoot.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { return $pathRoot }
    return $full.TrimEnd('\')
}

function Get-RootKey([string]$path) {
    $normal = (Normalize-RootPath $path).ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normal)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').Substring(0, 32) }
    finally { $sha.Dispose() }
}

function Write-JsonAtomic([string]$path, $value) {
    $directory = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($directory)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    $tmp = $path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = ConvertTo-Json -InputObject $value -Depth 12
    [System.IO.File]::WriteAllText($tmp, $json, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($path)) {
        try { [System.IO.File]::Replace($tmp, $path, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $path -Force }
    } else {
        [System.IO.File]::Move($tmp, $path)
    }
}

function Read-JsonFile([string]$path) {
    if (-not [System.IO.File]::Exists($path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { return $null }
}

function Get-PatternList([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return @() }
    return @($value -split '[;\r\n]+' | ForEach-Object { $_.Trim().Replace('/', '\') } | Where-Object { $_.Length -gt 0 })
}

function Test-FilterPatterns([string[]]$patterns, [string]$label) {
    foreach ($pattern in $patterns) {
        try { [void][System.Management.Automation.WildcardPattern]::new($pattern, [System.Management.Automation.WildcardOptions]::IgnoreCase) }
        catch { throw "Patrón de $label no válido: '$pattern'. $($_.Exception.Message)" }
    }
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
    if (Test-Pattern $relative $excludes) { return $false }
    return $true
}

function Test-ExcludedDirectory([string]$fullPath, [string]$root, [string[]]$excludes) {
    $relative = $fullPath.Substring($root.TrimEnd('\').Length).TrimStart('\')
    if (Test-Pattern $relative $excludes) { return $true }
    return (Test-Pattern ($relative + '\__bookforge_directory_marker__') $excludes)
}

function Format-Duration([double]$seconds) {
    if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds) -or $seconds -lt 0) { return 'Calculando…' }
    $ts = [TimeSpan]::FromSeconds([Math]::Min($seconds, 315360000))
    if ($ts.TotalDays -ge 1) { return ('{0} d {1:00} h' -f [int]$ts.TotalDays, $ts.Hours) }
    if ($ts.TotalHours -ge 1) { return ('{0} h {1:00} min' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1) { return ('{0} min {1:00} s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0} s' -f [int]$ts.TotalSeconds)
}

function Format-Bytes([long]$bytes) {
    if ($bytes -lt 1) { return '0 B' }
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$bytes
    $index = 0
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) { $value /= 1024; $index++ }
    return ('{0:N1} {1}' -f $value, $units[$index])
}

function ConvertTo-CsvField([object]$value) {
    return '"' + ([string]$value).Replace('"', '""') + '"'
}

function Write-Journal {
    param([string]$State, [string]$InputPath, [string]$OutputPath, [string]$Detail)
    if ($script:JournalWriter) {
        try {
            $values = @((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $State, $InputPath, $OutputPath, $Detail)
            $escaped = foreach ($value in $values) { ConvertTo-CsvField $value }
            $script:JournalWriter.WriteLine(($escaped -join ','))
            $script:JournalRowsSinceFlush++
            if ($script:JournalRowsSinceFlush -ge 25) {
                $script:JournalWriter.Flush()
                $script:JournalRowsSinceFlush = 0
            }
        } catch {
            try { $script:JournalWriter.Dispose() } catch {}
            $script:JournalWriter = $null
            Add-ErrorEntry -State 'LOG_WRITE_ERROR' -Path $InputPath -Detail ("No se pudo escribir el registro CSV: " + $_.Exception.Message)
        }
    }
    if ($State -match '^ERROR' -and $InputPath -and [System.IO.Path]::GetExtension($InputPath).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)) {
        $wasAdded = $false
        if ($script:FailedPaths) { $wasAdded = $script:FailedPaths.Add($InputPath) }
        if ($wasAdded -and $script:FailedPathsPath) { try { [System.IO.File]::AppendAllText($script:FailedPathsPath, $InputPath + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false)) } catch {} }
    }
    Add-Activity -State $State -Path $InputPath -Detail $Detail
    if ($State -match 'ERROR|WARNING|FAIL|FATAL') { Add-ErrorEntry -State $State -Path $InputPath -Detail $Detail }
}

function Save-FailedPathList {
    if ([string]::IsNullOrWhiteSpace($script:FailedPathsPath) -or -not $script:FailedPaths) { return }
    $tmp = $script:FailedPathsPath + '.tmp'
    $paths = [string[]]@($script:FailedPaths | Sort-Object)
    [System.IO.File]::WriteAllLines($tmp, $paths, [System.Text.UTF8Encoding]::new($false))
    if ([System.IO.File]::Exists($script:FailedPathsPath)) {
        try { [System.IO.File]::Replace($tmp, $script:FailedPathsPath, $null) }
        catch { Move-Item -LiteralPath $tmp -Destination $script:FailedPathsPath -Force }
    } else { [System.IO.File]::Move($tmp, $script:FailedPathsPath) }
}

function Remove-FailedPath([string]$path) {
    if ($script:FailedPaths -and $script:FailedPaths.Remove($path)) {
        $script:FailedListChanges++
        if ($script:FailedListChanges -ge 25) {
            try { Save-FailedPathList; $script:FailedListChanges = 0 } catch {}
        }
    }
}

function Add-Activity {
    param([string]$State, [string]$Path, [string]$Detail)
    if ($null -eq $script:ActivityItems) { return }
    $item = [pscustomobject]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); State = $State; File = [System.IO.Path]::GetFileName($Path); Path = $Path; Detail = $Detail }
    $script:ActivityItems.Add($item)
    while ($script:ActivityItems.Count -gt 600) { $script:ActivityItems.RemoveAt(0) }
}

function Add-ErrorEntry {
    param([string]$State, [string]$Path, [string]$Detail)
    if ($null -eq $script:ErrorItems) { return }
    $item = [pscustomobject]@{ Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); State = $State; Phase = [string]$script:Phase; File = [System.IO.Path]::GetFileName($Path); Path = $Path; Detail = $Detail }
    $script:ErrorItems.Add($item)
    while ($script:ErrorItems.Count -gt 2000) { $script:ErrorItems.RemoveAt(0) }
    if (-not [string]::IsNullOrWhiteSpace($script:ErrorLogPath)) {
        try { [System.IO.File]::AppendAllText($script:ErrorLogPath, ((ConvertTo-Json -InputObject $item -Compress -Depth 5) + [Environment]::NewLine), [System.Text.UTF8Encoding]::new($false)) } catch {}
    }
    if ($script:ui.ErrorCountLabel) { $script:ui.ErrorCountLabel.Text = "Entradas cargadas: $($script:ErrorItems.Count)" }
    if ($script:ErrorView) { $script:ErrorView.Refresh() }
    $failedBytes = 0
    if ($script:FailedPathsPath -and (Test-Path -LiteralPath $script:FailedPathsPath -PathType Leaf)) { try { $failedBytes = (Get-Item -LiteralPath $script:FailedPathsPath -ErrorAction Stop).Length } catch {} }
    $hasRetry = $failedBytes -gt 0
    $script:ui.RetryButton.IsEnabled = [bool]$hasRetry -and -not $script:IsRunning
    $script:ui.RetryErrorsButton.IsEnabled = [bool]$hasRetry -and -not $script:IsRunning
    Update-ErrorActionButtons
}

function Load-ErrorHistory([string]$path) {
    if ($null -eq $script:ErrorItems) { return }
    $script:ErrorItems.Clear()
    $script:LoadedErrorLogPath = $path
    if (-not [string]::IsNullOrWhiteSpace($path) -and [System.IO.File]::Exists($path)) {
        $queue = [System.Collections.Generic.Queue[object]]::new()
        try {
            foreach ($line in [System.IO.File]::ReadLines($path)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $entry = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                    $queue.Enqueue($entry)
                    while ($queue.Count -gt 2000) { [void]$queue.Dequeue() }
                } catch {}
            }
            foreach ($entry in $queue) { $script:ErrorItems.Add($entry) }
        } catch {}
    }
    if ($script:ui.ErrorCountLabel) { $script:ui.ErrorCountLabel.Text = "Entradas cargadas: $($script:ErrorItems.Count)" }
    if ($script:ErrorView) { $script:ErrorView.Refresh() }
    Update-ErrorActionButtons
}

function Update-ErrorActionButtons {
    if (-not $script:ui -or -not $script:ui.ErrorGrid) { return }
    $selected = $script:ui.ErrorGrid.SelectedItem
    $selectedPath = if ($selected) { [string]$selected.Path } else { '' }
    $selectedIsFile = -not [string]::IsNullOrWhiteSpace($selectedPath) -and [System.IO.Path]::GetExtension($selectedPath).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)
    $canSelectedRetry = $selectedIsFile -and (Test-Path -LiteralPath $selectedPath -PathType Leaf) -and -not $script:IsRunning
    if ($script:ui.RetrySelectedErrorButton) { $script:ui.RetrySelectedErrorButton.IsEnabled = [bool]$canSelectedRetry }
    $canOpen = $selected -and -not [string]::IsNullOrWhiteSpace($selectedPath) -and (Test-Path -LiteralPath $selectedPath)
    if ($script:ui.OpenSelectedErrorFolderButton) { $script:ui.OpenSelectedErrorFolderButton.IsEnabled = [bool]$canOpen }
    if ($script:ui.CopySelectedErrorButton) { $script:ui.CopySelectedErrorButton.IsEnabled = [bool]$selected }
}

function Update-PreflightReportCard {
    if (-not $script:ui -or -not $script:ui.PreflightReportLabel) { return }
    $script:ui.PreflightReportLabel.Text = 'Todavía no hay un informe previo para este trabajo.'
    $script:ui.OpenPreflightReportButton.IsEnabled = $false
    if ([string]::IsNullOrWhiteSpace($script:PreflightReportPath) -or -not (Test-Path -LiteralPath $script:PreflightReportPath -PathType Leaf)) { return }
    $preflight = Read-JsonFile $script:PreflightReportPath
    if (-not $preflight) { return }
    $created = [string]$preflight.CreatedAt
    try { $created = [DateTime]::Parse($created).ToString('yyyy-MM-dd HH:mm:ss') } catch {}
    $decision = switch ([string]$preflight.Decision) { 'Started' { 'Aceptado: se inició la conversión' } 'Cancelled' { 'Rechazado: no se convirtió ningún libro' } default { 'Pendiente de decisión' } }
    $free = if ($null -ne $preflight.FreeBytes -and [long]$preflight.FreeBytes -ge 0) { Format-Bytes ([long]$preflight.FreeBytes) } else { 'No disponible' }
    $script:ui.PreflightReportLabel.Text = "Fecha: $created`r`n$decision`r`nEPUB encontrados: $($preflight.FoundEpubs) · Incluidos: $($preflight.SelectedEpubs) · MOBI existentes: $($preflight.ExistingMobi)`r`nConversiones potenciales: $($preflight.PotentialConversions) · Carpetas: $($preflight.DirectoriesScanned) · Avisos: $($preflight.AccessWarnings)`r`nTamaño de EPUB: $(Format-Bytes ([long]$preflight.SourceBytes)) · Espacio libre: $free`r`nFiltros de inclusión: $(if ([string]::IsNullOrWhiteSpace([string]$preflight.IncludePatterns)) { 'Ninguno' } else { [string]$preflight.IncludePatterns }) · Exclusión: $(if ([string]::IsNullOrWhiteSpace([string]$preflight.ExcludePatterns)) { 'Ninguna' } else { [string]$preflight.ExcludePatterns })"
    $script:ui.OpenPreflightReportButton.IsEnabled = $true
}

function Set-Status([string]$text) {
    $script:ui.StatusLabel.Text = $text
}

function Set-InputLock([bool]$locked) {
    $enabled = -not $locked
    foreach ($name in @('RootPathBox', 'BrowseButton', 'IncludePatternsBox', 'ExcludePatternsBox', 'SkipExistingCheck', 'TestModeCombo', 'VerifyCombo', 'ProfileNameBox', 'ProfileCombo', 'SaveProfileButton', 'LoadProfileButton')) {
        if ($script:ui[$name]) { $script:ui[$name].IsEnabled = $enabled }
    }
}

function Set-ManifestStatus([string]$status) {
    if (-not $script:Manifest -or [string]::IsNullOrWhiteSpace($script:ManifestPath)) { return }
    if ($script:JournalWriter) { try { $script:JournalWriter.Flush(); $script:JournalRowsSinceFlush = 0 } catch {} }
    if ($script:FailedListChanges -gt 0) { try { Save-FailedPathList; $script:FailedListChanges = 0 } catch {} }
    $script:Manifest.Status = $status
    $script:Manifest.Updated = (Get-Date).ToString('o')
    $script:Manifest.Stats = [pscustomobject]@{
        Total = $script:Total
        Converted = $script:Converted
        Skipped = $script:Skipped
        Failed = $script:Failed
        Finished = $script:FinishedCount
        LateSkipped = $script:LateSkipped
        Attempted = $script:AttemptedCount
        Warnings = $script:ScanWarnings
        VerificationPassed = $script:VerificationPassed
        VerificationFailed = $script:VerificationFailed
    }
    $script:Manifest.VerifySeen = $script:VerifySeen
    $script:Manifest.VerifyCandidates = @($script:VerifyCandidates.ToArray())
    $script:Manifest.ElapsedSeconds = [Math]::Round($script:ElapsedPriorSeconds + $script:RunTimer.Elapsed.TotalSeconds, 2)
    $script:Manifest.ConversionSeconds = [Math]::Round($script:ConversionPriorSeconds + $script:ConversionTimer.Elapsed.TotalSeconds, 2)
    Write-JsonAtomic $script:ManifestPath $script:Manifest
    $rootWorkspace = Join-Path $script:JobsRoot $script:RootKey
    $latestPath = Join-Path $rootWorkspace 'latest.json'
    Write-JsonAtomic $latestPath ([pscustomobject]@{ ManifestPath = $script:ManifestPath; Updated = (Get-Date).ToString('o') })
}

function Get-Settings {
    $selectedParallel = 3
    if ($script:ui.ParallelCombo.SelectedItem) { $selectedParallel = [int]$script:ui.ParallelCombo.SelectedItem }
    return [pscustomobject]@{
        Root = $script:ui.RootPathBox.Text.Trim()
        IncludePatterns = $script:ui.IncludePatternsBox.Text
        ExcludePatterns = $script:ui.ExcludePatternsBox.Text
        SkipExisting = [bool]$script:ui.SkipExistingCheck.IsChecked
        ParallelCount = $selectedParallel
        AutoParallel = [bool]$script:ui.AutoParallelCheck.IsChecked
        LowImpact = [bool]$script:ui.LowImpactCheck.IsChecked
        TestMode = [string]$script:ui.TestModeCombo.SelectedItem
        VerifyCount = [int]$script:ui.VerifyCombo.SelectedItem
        NightMode = [bool]$script:ui.NightModeCheck.IsChecked
        Notifications = [bool]$script:ui.NotificationsCheck.IsChecked
        Sound = [bool]$script:ui.SoundCheck.IsChecked
        Shutdown = [bool]$script:ui.ShutdownCheck.IsChecked
        Theme = $script:ThemeName
    }
}

function Apply-Settings($settings) {
    if (-not $settings) { return }
    if ($settings.Root -and (Test-Path -LiteralPath ([string]$settings.Root) -PathType Container)) { $script:ui.RootPathBox.Text = [string]$settings.Root; $script:RootPath = [string]$settings.Root; $script:ui.StartButton.IsEnabled = $true; Update-RecoveryState }
    if ($null -ne $settings.IncludePatterns) { $script:ui.IncludePatternsBox.Text = [string]$settings.IncludePatterns }
    if ($null -ne $settings.ExcludePatterns) { $script:ui.ExcludePatternsBox.Text = [string]$settings.ExcludePatterns }
    if ($null -ne $settings.SkipExisting) { $script:ui.SkipExistingCheck.IsChecked = [bool]$settings.SkipExisting }
    if ($null -ne $settings.AutoParallel) { $script:ui.AutoParallelCheck.IsChecked = [bool]$settings.AutoParallel }
    if ($null -ne $settings.LowImpact) { $script:ui.LowImpactCheck.IsChecked = [bool]$settings.LowImpact }
    if ($null -ne $settings.TestMode) {
        $item = [string]$settings.TestMode
        if ($script:ui.TestModeCombo.Items.Contains($item)) { $script:ui.TestModeCombo.SelectedItem = $item }
    }
    if ($null -ne $settings.VerifyCount -and $script:ui.VerifyCombo.Items.Contains([int]$settings.VerifyCount)) { $script:ui.VerifyCombo.SelectedItem = [int]$settings.VerifyCount }
    if ($null -ne $settings.ParallelCount) {
        $v = [Math]::Max(1, [Math]::Min($script:LogicalProcessors, [int]$settings.ParallelCount))
        $script:ui.ParallelCombo.SelectedItem = $v
    }
    if ($null -ne $settings.NightMode) { $script:ui.NightModeCheck.IsChecked = [bool]$settings.NightMode }
    if ($null -ne $settings.Notifications) { $script:ui.NotificationsCheck.IsChecked = [bool]$settings.Notifications }
    if ($null -ne $settings.Sound) { $script:ui.SoundCheck.IsChecked = [bool]$settings.Sound }
    if ($null -ne $settings.Shutdown) { $script:ui.ShutdownCheck.IsChecked = [bool]$settings.Shutdown }
    $script:ui.ParallelCombo.IsEnabled = -not [bool]$script:ui.AutoParallelCheck.IsChecked
    if ($settings.Theme -in @('Dark', 'Light')) { Set-Theme ([string]$settings.Theme) }
}

function Load-Preferences {
    $preferences = Read-JsonFile $script:PrefsPath
    if ($preferences) { Apply-Settings $preferences }
}

function Save-Preferences {
    try { Write-JsonAtomic $script:PrefsPath (Get-Settings) } catch {}
}

function Load-Profiles {
    $loaded = Read-JsonFile $script:ProfilesPath
    $script:Profiles = [System.Collections.Generic.List[object]]::new()
    if ($loaded) { foreach ($profile in @($loaded)) { $script:Profiles.Add($profile) } }
    $script:ui.ProfileCombo.Items.Clear()
    foreach ($profile in $script:Profiles) { [void]$script:ui.ProfileCombo.Items.Add([string]$profile.Name) }
}

function Save-Profile {
    $name = $script:ui.ProfileNameBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.MessageBox]::Show('Escribe un nombre para el perfil.', 'Guardar perfil', 'OK', 'Information') | Out-Null
        return
    }
    $settings = Get-Settings
    $settings | Add-Member -NotePropertyName Name -NotePropertyValue $name -Force
    $existingIndex = -1
    for ($i = 0; $i -lt $script:Profiles.Count; $i++) { if ([string]$script:Profiles[$i].Name -eq $name) { $existingIndex = $i; break } }
    if ($existingIndex -ge 0) {
        $answer = Show-ThemedYesNo -message "El perfil '$name' ya existe. ¿Quieres sustituirlo?" -title 'Guardar perfil' -kind 'Question' -defaultYes $false
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $script:Profiles[$existingIndex] = $settings
    } else { $script:Profiles.Add($settings) }
    Write-JsonAtomic -path $script:ProfilesPath -value ([object[]]$script:Profiles.ToArray())
    Load-Profiles
    $script:ui.ProfileCombo.SelectedItem = $name
    Add-Activity -State 'PROFILE_SAVED' -Path $name -Detail 'Perfil guardado.'
}

function Load-SelectedProfile {
    if ($script:IsRunning -or $script:DuplicateMode) { return }
    if (-not $script:ui.ProfileCombo.SelectedItem) { return }
    $name = [string]$script:ui.ProfileCombo.SelectedItem
    foreach ($profile in $script:Profiles) {
        if ([string]$profile.Name -eq $name) {
            Apply-Settings $profile
            Add-Activity -State 'PROFILE_LOADED' -Path $name -Detail 'Perfil aplicado.'
            return
        }
    }
}

function Set-Theme([string]$theme) {
    if (-not $script:Window) { return }
    $script:ThemeName = $theme
    $resource = $script:Window.Resources
    if ($theme -eq 'Light') {
        $resource['AppBackgroundBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#F1F5F9'))
        $resource['PanelBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
        $resource['CardBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#F8FAFC'))
        $resource['TextBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#0F172A'))
        $resource['MutedBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#64748B'))
        $resource['BorderBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#CBD5E1'))
        $resource['InputBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#FFFFFF'))
        $script:ui.ThemeButton.Content = 'Tema oscuro'
    } else {
        $resource['AppBackgroundBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#0F172A'))
        $resource['PanelBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#172033'))
        $resource['CardBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#1E293B'))
        $resource['TextBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#F8FAFC'))
        $resource['MutedBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#94A3B8'))
        $resource['BorderBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#334155'))
        $resource['InputBrush'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.ColorConverter]::ConvertFromString('#0B1220'))
        $script:ui.ThemeButton.Content = 'Tema claro'
    }
    Save-Preferences
}

function Get-DriveFreeBytes([string]$path) {
    try {
        $driveRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($path))
        $drive = [System.IO.DriveInfo]::new($driveRoot)
        if ($drive.IsReady) { return [long]$drive.AvailableFreeSpace }
    } catch {}
    return [long]-1
}

function New-JobWorkspace([string]$root, $settings) {
    $script:ElapsedPriorSeconds = 0.0
    $script:ConversionPriorSeconds = 0.0
    $script:PendingToConvert = 0
    $script:LateSkipped = 0
    $script:LastDiskCheck = [DateTime]::MinValue
    $script:AttemptedCount = 0
    $script:ActiveSeconds = 0.0
    $script:Total = 0
    $script:Converted = 0
    $script:Skipped = 0
    $script:Failed = 0
    $script:FinishedCount = 0
    $script:ScanWarnings = 0
    $script:DirectoriesSeen = 0
    $script:RunTimer.Reset()
    $script:ConversionTimer.Reset()
    $script:RootPath = Normalize-RootPath $root
    $script:RootKey = Get-RootKey $script:RootPath
    $rootWorkspace = Join-Path $script:JobsRoot $script:RootKey
    New-Item -ItemType Directory -Path $rootWorkspace -Force | Out-Null
    $jobId = (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $script:JobDir = Join-Path $rootWorkspace $jobId
    New-Item -ItemType Directory -Path $script:JobDir -Force | Out-Null
    $script:ManifestPath = Join-Path $script:JobDir 'job.json'
    $script:InventoryPath = Join-Path $script:JobDir 'inventory.txt'
    $script:JournalPath = Join-Path $script:JobDir 'events.csv'
    $script:ReportPath = Join-Path $script:JobDir 'summary.json'
    $script:PreflightReportPath = Join-Path $script:JobDir 'preflight.json'
    $script:ErrorLogPath = Join-Path $script:JobDir 'errors.jsonl'
    $script:LoadedErrorLogPath = ''
    $script:CurrentPreflightReport = $null
    $script:Manifest = [pscustomobject]@{
        Version = '1.0'
        PreflightReportPath = $script:PreflightReportPath
        ErrorLogPath = $script:ErrorLogPath
        JobId = $jobId
        Root = $script:RootPath
        RootKey = $script:RootKey
        Created = (Get-Date).ToString('o')
        Updated = (Get-Date).ToString('o')
        Status = 'Scanning'
        InventoryPath = $script:InventoryPath
        JournalPath = $script:JournalPath
        ReportPath = $script:ReportPath
        FailedPathsPath = (Join-Path $script:JobDir 'failed.txt')
        Settings = $settings
        Total = 0
        PreflightDecision = ''
        PreflightDecisionAt = ''
        AllFound = 0
        AllSourceBytes = [long]0
        PreExistingMobi = 0
        AllPreExistingMobi = 0
        InventoryBytes = [long]0
        Filters = [pscustomobject]@{ Include = @(); Exclude = @() }
        VerifySeen = 0
        VerifyCandidates = @()
        ElapsedSeconds = 0.0
        ConversionSeconds = 0.0
        Stats = [pscustomobject]@{ Total = 0; Converted = 0; Skipped = 0; Failed = 0; Finished = 0; Warnings = 0 }
    }
    $script:FailedPathsPath = [string]$script:Manifest.FailedPathsPath
    $script:FailedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:FailedListChanges = 0
    $script:JournalRowsSinceFlush = 0
    [System.IO.File]::WriteAllText($script:FailedPathsPath, '', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($script:ErrorLogPath, '', [System.Text.UTF8Encoding]::new($false))
    $script:IncludePatterns = Get-PatternList ([string]$settings.IncludePatterns)
    $script:ExcludePatterns = Get-PatternList ([string]$settings.ExcludePatterns)
    $script:VerifyCandidates.Clear()
    $script:VerifySeen = 0
    $script:VerificationFailed = 0
    $script:VerificationPassed = 0
    Set-ManifestStatus 'Scanning'
    $script:JournalWriter = [System.IO.StreamWriter]::new($script:JournalPath, $false, [System.Text.UTF8Encoding]::new($true))
    $script:JournalRowsSinceFlush = 0
    $script:JournalWriter.WriteLine('Fecha,Estado,EPUB,MOBI,Detalle')
    $script:JournalWriter.Flush()
}

function Ensure-ManifestProperties($manifest) {
    if ($null -eq $manifest) { return $null }
    $defaults = [ordered]@{
        AllFound = 0
        AllSourceBytes = [long]0
        PreExistingMobi = 0
        AllPreExistingMobi = 0
        InventoryBytes = [long]0
        PreflightReportPath = ''
        ErrorLogPath = ''
        PreflightDecision = ''
        PreflightDecisionAt = ''
        Filters = [pscustomobject]@{ Include = @(); Exclude = @() }
        VerifySeen = 0
        VerifyCandidates = @()
        ElapsedSeconds = 0.0
        ConversionSeconds = 0.0
    }
    foreach ($name in $defaults.Keys) {
        if ($null -eq $manifest.PSObject.Properties[$name]) {
            $manifest | Add-Member -MemberType NoteProperty -Name $name -Value $defaults[$name]
        }
    }
    return $manifest
}

function Get-LatestManifest([string]$root) {
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    $key = Get-RootKey $root
    $latest = Join-Path (Join-Path $script:JobsRoot $key) 'latest.json'
    $pointer = Read-JsonFile $latest
    if (-not $pointer -or -not $pointer.ManifestPath) { return $null }
    $path = [string]$pointer.ManifestPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $manifest = Read-JsonFile $path
    if (-not $manifest -or -not $manifest.InventoryPath) { return $null }
    $manifest = Ensure-ManifestProperties $manifest
    return [pscustomobject]@{ Path = $path; Manifest = $manifest }
}

function Update-RecoveryState {
    $root = $script:ui.RootPathBox.Text.Trim()
    $script:RootPath = $root
    $script:RootKey = if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-Path -LiteralPath $root -PathType Container)) { Get-RootKey $root } else { '' }
    $script:ResumeAvailable = $false
    $script:Recovery = $null
    $script:Manifest = $null
    $script:ManifestPath = ''
    $script:JobDir = ''
    $script:InventoryPath = ''
    $script:JournalPath = ''
    $script:ReportPath = ''
    $script:PreflightReportPath = ''
    $script:ErrorLogPath = ''
    $script:FailedPathsPath = ''
    $script:ui.ResumeButton.IsEnabled = $false
    $script:ui.RetryButton.IsEnabled = $false
    $script:ui.RetryErrorsButton.IsEnabled = $false
    $script:ui.OpenReportButton.IsEnabled = $false
    $script:ui.OpenJournalButton.IsEnabled = $false
    $script:ui.OpenJobFolderButton.IsEnabled = $false
    $script:ui.ResumeInfoLabel.Text = 'No hay un trabajo anterior pendiente.'
    $script:ui.ReportPathLabel.Text = 'Aún no hay informe de trabajo.'
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) { Load-ErrorHistory ''; Update-PreflightReportCard; return }
    $latest = Get-LatestManifest $root
    if (-not $latest) { Load-ErrorHistory ''; Update-PreflightReportCard; return }
    $manifest = $latest.Manifest
    $script:Manifest = $manifest
    $script:ManifestPath = $latest.Path
    $script:JobDir = Split-Path -Parent $latest.Path
    $script:InventoryPath = [string]$manifest.InventoryPath
    $script:JournalPath = [string]$manifest.JournalPath
    $script:ReportPath = [string]$manifest.ReportPath
    $script:PreflightReportPath = if ($manifest.PreflightReportPath) { [string]$manifest.PreflightReportPath } else { Join-Path $script:JobDir 'preflight.json' }
    $script:ErrorLogPath = if ($manifest.ErrorLogPath) { [string]$manifest.ErrorLogPath } else { Join-Path $script:JobDir 'errors.jsonl' }
    $script:FailedPathsPath = if ($manifest.FailedPathsPath) { [string]$manifest.FailedPathsPath } else { Join-Path $script:JobDir 'failed.txt' }
    if ($manifest.JournalPath -and (Test-Path -LiteralPath ([string]$manifest.JournalPath) -PathType Leaf)) { $script:ui.ReportPathLabel.Text = [string]$manifest.ReportPath }
    Load-ErrorHistory $script:ErrorLogPath
    Update-PreflightReportCard
    $script:ui.OpenReportButton.IsEnabled = (($manifest.ReportPath -and (Test-Path -LiteralPath ([string]$manifest.ReportPath) -PathType Leaf)) -or ($manifest.JournalPath -and (Test-Path -LiteralPath ([string]$manifest.JournalPath) -PathType Leaf)))
    $script:ui.OpenJournalButton.IsEnabled = [bool]($manifest.JournalPath -and (Test-Path -LiteralPath ([string]$manifest.JournalPath) -PathType Leaf))
    $script:ui.OpenJobFolderButton.IsEnabled = [bool](Test-Path -LiteralPath $script:JobDir -PathType Container)
    $failedBytes = 0
    if (Test-Path -LiteralPath $script:FailedPathsPath -PathType Leaf) { try { $failedBytes = (Get-Item -LiteralPath $script:FailedPathsPath -ErrorAction Stop).Length } catch {} }
    $script:ui.RetryButton.IsEnabled = ($failedBytes -gt 0) -and -not $script:IsRunning
    $script:ui.RetryErrorsButton.IsEnabled = $script:ui.RetryButton.IsEnabled
    $status = [string]$manifest.Status
    if ($status -in @('Paused', 'Running', 'Interrupted', 'Ready', 'ScanStopped') -and (Test-Path -LiteralPath ([string]$manifest.InventoryPath) -PathType Leaf)) {
        $script:ResumeAvailable = $true
        $script:Recovery = $latest
        if ($status -eq 'Running') { $status = 'Interrupted' }
        $script:ui.ResumeButton.IsEnabled = $true
        $createdText = [string]$manifest.Created
        try { $createdText = [DateTime]::Parse($createdText).ToString('dd/MM HH:mm') } catch {}
        $script:ui.ResumeInfoLabel.Text = "Trabajo recuperable: $status · $($manifest.Total) elementos inventariados · creado $createdText"
    }
}

function Dispose-Enumerators {
    foreach ($enumerator in @($script:FileEnumerator, $script:DirectoryEnumerator)) {
        if ($null -ne $enumerator) { try { $enumerator.Dispose() } catch {} }
    }
    $script:FileEnumerator = $null
    $script:DirectoryEnumerator = $null
}

function Begin-ScanDirectory {
    while ($script:ScanStack.Count -gt 0) {
        $script:CurrentScanDirectory = $script:ScanStack.Pop()
        $script:DirectoriesSeen++
        $script:ScanMode = 'Files'
        try {
            $script:FileEnumerator = ([System.IO.Directory]::EnumerateFiles($script:CurrentScanDirectory, '*', [System.IO.SearchOption]::TopDirectoryOnly)).GetEnumerator()
        } catch {
            $script:ScanWarnings++
            Write-Journal 'SCAN_WARNING' $script:CurrentScanDirectory '' $_.Exception.Message
            $script:FileEnumerator = $null
            $script:ScanMode = 'Directories'
        }
        return $true
    }
    return $false
}

function Begin-NewScan {
    $settings = Get-Settings
    $root = $settings.Root
    try {
        $includePatternsToCheck = Get-PatternList ([string]$settings.IncludePatterns)
        $excludePatternsToCheck = Get-PatternList ([string]$settings.ExcludePatterns)
        Test-FilterPatterns -patterns $includePatternsToCheck -label 'inclusión'
        Test-FilterPatterns -patterns $excludePatternsToCheck -label 'exclusión'
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Filtro no válido', 'OK', 'Warning') | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        [System.Windows.MessageBox]::Show('Selecciona una carpeta raíz válida.', 'Carpeta necesaria', 'OK', 'Warning') | Out-Null
        return
    }
    if (-not $script:ConverterPath -or -not (Test-Path -LiteralPath $script:ConverterPath -PathType Leaf)) {
        $answer = Show-ThemedYesNo -message 'No se encuentra ebook-convert.exe. Instala Calibre o localiza el ejecutable. ¿Quieres buscarlo ahora?' -title 'Calibre' -kind 'Warning' -defaultYes $false
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Selecciona ebook-convert.exe'
        $dialog.Filter = 'ebook-convert.exe|ebook-convert.exe'
        $dialog.CheckFileExists = $true
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $script:ConverterPath = $dialog.FileName
    }
    if ($script:ResumeAvailable -and $script:Recovery -and $script:Recovery.Manifest) {
        $recoveryStatus = [string]$script:Recovery.Manifest.Status
        $recoveryQuestion = "Hay un trabajo recuperable ($recoveryStatus) para esta biblioteca.`r`n`r`nSi comienzas un trabajo nuevo, el trabajo anterior se conservará en Informes, pero dejará de ser la recuperación predeterminada.`r`n`r`n¿Quieres iniciar un trabajo nuevo?"
        $recoveryAnswer = Show-ThemedYesNo -message $recoveryQuestion -title 'Trabajo anterior recuperable' -kind 'Warning' -defaultYes $false
        if ($recoveryAnswer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }
    try { New-JobWorkspace $root $settings }
    catch {
        [System.Windows.MessageBox]::Show("No se puede preparar el trabajo: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
        return
    }
    $script:Files = [System.Collections.Generic.List[object]]::new()
    $script:IncludePatterns = Get-PatternList ([string]$settings.IncludePatterns)
    $script:ExcludePatterns = Get-PatternList ([string]$settings.ExcludePatterns)
    $script:FailedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:VerifyCandidates.Clear()
    $script:VerifySeen = 0
    $script:VerificationFailed = 0
    $script:VerificationPassed = 0
    $script:ScanStack = [System.Collections.Generic.Stack[string]]::new()
    $script:ScanStack.Push($script:RootPath)
    $script:FileEnumerator = $null
    $script:DirectoryEnumerator = $null
    $script:CurrentScanDirectory = ''
    $script:ScanMode = 'Files'
    $script:DirectoriesSeen = 0
    $script:ScanWarnings = 0
    $script:ScanEntries = 0
    $script:InventoryExisting = 0
    $script:InventoryAllExisting = 0
    $script:InventoryAllBytes = 0
    $script:InventoryAllMatchedInputBytes = 0
    $script:InventoryAllOutputBytes = 0
    $script:LastCheckpointAt = Get-Date
    $script:InventorySourceBytes = 0
    $script:InventoryOutputBytes = 0
    $script:PendingToConvert = 0
    $script:LateSkipped = 0
    $script:DiskPauseTriggered = $false
    $script:LastDiskCheck = [DateTime]::MinValue
    $script:AttemptedCount = 0
    $script:ActiveSeconds = 0.0
    $script:ElapsedPriorSeconds = 0.0
    $script:ConversionPriorSeconds = 0.0
    $script:Index = 0
    $script:Total = 0
    $script:Converted = 0
    $script:Skipped = 0
    $script:Failed = 0
    $script:FinishedCount = 0
    $script:PauseRequested = $false
    $script:RunMode = 'New'
    $script:RunTimer.Restart()
    $script:LastCheckpointAt = Get-Date
    $script:ConversionTimer.Reset()
    $script:Phase = 'Scan'
    $script:IsRunning = $true
    $script:ui.StartButton.IsEnabled = $false
    $script:ui.ResumeButton.IsEnabled = $false
    $script:ui.PauseButton.Content = 'Detener inventario'
    $script:ui.PauseButton.IsEnabled = $true
    Set-InputLock $true
    $script:ui.DuplicateButton.IsEnabled = $false
    $script:ui.ProgressBar.IsIndeterminate = $true
    $script:ui.ProgressBar.Value = 0
    $script:ui.ProgressCaption.Text = 'INVENTARIO'
    $script:ui.ProgressPercent.Text = '…'
    $script:ActivityItems.Clear()
    Load-ErrorHistory $script:ErrorLogPath
    $script:ui.ErrorCountLabel.Text = '0'
    $script:ui.IncludedLabel.Text = 'Inventario en curso'
    Set-Status 'Inventariando EPUB y subcarpetas…'
    Add-Activity -State 'SCAN_START' -Path $script:RootPath -Detail 'Inicio del inventario.'
    $script:Timer.Start()
    if ($settings.NightMode) { Set-KeepAwake $true }
    Update-RecoveryState
}

function Select-Sample([System.Collections.Generic.List[object]]$source, [int]$sampleCount) {
    if ($sampleCount -le 0 -or $sampleCount -ge $source.Count) { return $source }
    $random = [System.Random]::new()
    $selected = [System.Collections.Generic.HashSet[int]]::new()
    while ($selected.Count -lt $sampleCount) { [void]$selected.Add($random.Next(0, $source.Count)) }
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($i in $selected) { $result.Add($source[$i]) }
    return $result
}

function Finish-Inventory {
    Dispose-Enumerators
    $settings = $script:Manifest.Settings
    $allCount = $script:Files.Count
    $allBytes = [long]$script:InventoryAllBytes
    $allExisting = [int]$script:InventoryAllExisting
    $testMode = [string]$settings.TestMode
    $target = 0
    if ($testMode -match '^(20|100|500)$') { $target = [int]$testMode }
    if ($target -gt 0 -and $target -lt $script:Files.Count) {
        $samplePool = $script:Files
        if ([bool]$settings.SkipExisting) {
            $pendingPool = [System.Collections.Generic.List[object]]::new()
            foreach ($candidate in $script:Files) { if (-not [bool]$candidate.OutputExists) { $pendingPool.Add($candidate) } }
            if ($pendingPool.Count -gt 0) { $samplePool = $pendingPool }
        }
        $script:Files = Select-Sample $samplePool $target
    }
    if ([bool]$settings.SkipExisting -and $script:Files.Count -gt 1) {
        $orderedFiles = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $script:Files) { if ([bool]$item.OutputExists) { $orderedFiles.Add($item) } }
        foreach ($item in $script:Files) { if (-not [bool]$item.OutputExists) { $orderedFiles.Add($item) } }
        $script:Files = $orderedFiles
    }
    $script:Total = $script:Files.Count
    $script:InventorySourceBytes = 0
    $script:InventoryExisting = 0
    $script:InventoryOutputBytes = 0
    foreach ($item in $script:Files) {
        $script:InventorySourceBytes += [long]$item.Length
        if ($item.OutputExists) { $script:InventoryExisting++; $script:InventoryOutputBytes += [long]$item.OutputLength }
    }
    try {
        $writer = [System.IO.StreamWriter]::new($script:InventoryPath, $false, [System.Text.UTF8Encoding]::new($false))
        try { foreach ($item in $script:Files) { $writer.WriteLine([string]$item.Path) } }
        finally { $writer.Dispose() }
    } catch {
        Finalize-Job 'Failed' $_.Exception.Message
        [System.Windows.MessageBox]::Show("No se pudo guardar el inventario: $($_.Exception.Message)", 'Error de inventario', 'OK', 'Error') | Out-Null
        return
    }
    $script:Manifest.Total = $script:Total
    $script:Manifest.AllFound = $allCount
    $script:Manifest.AllSourceBytes = $allBytes
    $script:Manifest.PreExistingMobi = $script:InventoryExisting
    $script:Manifest.AllPreExistingMobi = $allExisting
    $script:Manifest.InventoryBytes = $script:InventorySourceBytes
    $script:Manifest.Filters = [pscustomobject]@{ Include = $settings.IncludePatterns; Exclude = $settings.ExcludePatterns }
    $script:Manifest.Settings = $settings
    Set-ManifestStatus 'Ready'
    $script:Phase = 'Preview'
    $script:ui.ProgressBar.IsIndeterminate = $false
    $script:ui.ProgressBar.Value = 100
    $script:ui.ProgressCaption.Text = 'INVENTARIO COMPLETO'
    $script:ui.ProgressPercent.Text = '100 %'
    Set-Status 'Inventario completo · revisa el informe previo.'
    $script:ui.IncludedLabel.Text = "$($script:Total) EPUB en este trabajo · $($script:DirectoriesSeen) carpetas recorridas"
    $driveFree = Get-DriveFreeBytes $script:RootPath
    $estimatedNeed = [long]0
    $pending = $script:Total
    if ($settings.SkipExisting) { $pending = [Math]::Max(0, $script:Total - $script:InventoryExisting) }
    $pendingSourceBytes = [long]0
    foreach ($item in $script:Files) { if (-not $settings.SkipExisting -or -not [bool]$item.OutputExists) { $pendingSourceBytes += [long]$item.Length } }
    $estimatedNeed = if ($pendingSourceBytes -gt 0) { [long]($pendingSourceBytes * 1.25 + 134217728) } else { [long]0 }
    $estimateMethod = 'estimación conservadora a partir del tamaño de los EPUB'
    if ($script:InventoryAllExisting -ge 5 -and $script:InventoryAllMatchedInputBytes -gt 0 -and $pendingSourceBytes -gt 0) {
        $observedRatio = [double]$script:InventoryAllOutputBytes / [double]$script:InventoryAllMatchedInputBytes
        $estimatedNeed = [long]($pendingSourceBytes * [Math]::Max(1.15, $observedRatio * 1.15) + 134217728)
        $estimateMethod = 'estimación basada en MOBI existentes y un margen del 15 %'
    }
    $needText = Format-Bytes $estimatedNeed
    $freeText = if ($driveFree -ge 0) { Format-Bytes $driveFree } else { 'No disponible' }
    $estimateText = if ($driveFree -lt 0) { 'No se pudo medir el espacio libre de la unidad; revísalo antes de continuar.' } elseif ($driveFree -lt $estimatedNeed) { 'ADVERTENCIA: el espacio libre puede ser insuficiente.' } else { 'Espacio aparentemente suficiente.' }
    $estimateText += " Método: $estimateMethod."
    if ($script:ScanWarnings -gt 0) { $estimateText += " Avisos de acceso: $($script:ScanWarnings)." }
    if (-not $settings.SkipExisting -and $script:InventoryExisting -gt 0) { $estimateText += " Se reemplazarán $($script:InventoryExisting) salidas existentes tras crear una copia temporal." }
    $typeText = if ($target -gt 0) { "MODO DE PRUEBA: muestra aleatoria de $($script:Total) de $allCount EPUB." } else { 'MODO COMPLETO.' }
    $message = "Informe previo`r`n`r`nEPUB encontrados según los filtros: $allCount`r`nEPUB incluidos en este trabajo: $($script:Total)`r`nMOBI existentes con contenido junto a los EPUB incluidos: $allExisting`r`nMOBI existentes con contenido en este trabajo: $($script:InventoryExisting)`r`nConversiones potenciales según la opción de omisión: $pending`r`nCarpetas recorridas: $($script:DirectoriesSeen)`r`nAvisos de acceso: $($script:ScanWarnings)`r`n`r`nTamaño EPUB del trabajo: $(Format-Bytes $script:InventorySourceBytes)`r`nEspacio libre en la unidad de destino: $freeText`r`nReserva orientativa para nuevas salidas: $needText`r`n$estimateText`r`n`r`n$typeText`r`n`r`n¿Quieres comenzar?"
    Add-Activity -State 'SCAN_COMPLETE' -Path $script:RootPath -Detail "$allCount EPUB encontrados; $($script:Total) seleccionados para el trabajo."
    $defaultYes = ($driveFree -ge 0 -and $driveFree -ge $estimatedNeed)
    $promptKind = if ($defaultYes) { 'Question' } else { 'Warning' }
    $createdAt = (Get-Date).ToString('o')
    $script:CurrentPreflightReport = [pscustomobject]@{
        Version = '1.0'
        CreatedAt = $createdAt
        DecisionAt = ''
        Decision = 'Pending'
        Root = $script:RootPath
        IncludePatterns = [string]$settings.IncludePatterns
        ExcludePatterns = [string]$settings.ExcludePatterns
        TestMode = [string]$settings.TestMode
        SkipExisting = [bool]$settings.SkipExisting
        FoundEpubs = [long]$allCount
        SelectedEpubs = [long]$script:Total
        ExistingMobi = [long]$allExisting
        ExistingMobiInWork = [long]$script:InventoryExisting
        PotentialConversions = [long]$pending
        DirectoriesScanned = [long]$script:DirectoriesSeen
        AccessWarnings = [long]$script:ScanWarnings
        SourceBytes = [long]$script:InventorySourceBytes
        FreeBytes = [long]$driveFree
        EstimatedRequiredBytes = [long]$estimatedNeed
        EstimateMethod = $estimateMethod
        EstimateText = $estimateText
        PreviewText = $message
    }
    try {
        Write-JsonAtomic $script:PreflightReportPath $script:CurrentPreflightReport
        $script:Manifest.PreflightReportPath = $script:PreflightReportPath
        $script:Manifest.PreflightDecision = 'Pending'
        Set-ManifestStatus 'Ready'
        Update-PreflightReportCard
    } catch {
        Write-Journal 'REPORT_WARNING' $script:RootPath $script:PreflightReportPath $_.Exception.Message
    }
    $answer = Show-ThemedYesNo -message $message -title 'Revisar inventario' -kind $promptKind -defaultYes $defaultYes
    $script:CurrentPreflightReport.Decision = if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { 'Started' } else { 'Cancelled' }
    $script:CurrentPreflightReport.DecisionAt = (Get-Date).ToString('o')
    try {
        Write-JsonAtomic $script:PreflightReportPath $script:CurrentPreflightReport
        $script:Manifest.PreflightDecision = [string]$script:CurrentPreflightReport.Decision
        $script:Manifest.PreflightDecisionAt = [string]$script:CurrentPreflightReport.DecisionAt
        Set-ManifestStatus 'Ready'
    } catch { Write-Journal 'REPORT_WARNING' $script:RootPath $script:PreflightReportPath $_.Exception.Message }
    Update-PreflightReportCard
    Add-Activity -State $(if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { 'PREFLIGHT_ACCEPTED' } else { 'PREFLIGHT_CANCELLED' }) -Path $script:RootPath -Detail $(if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { 'El informe previo fue aceptado.' } else { 'El informe previo fue rechazado; no se inició ninguna conversión.' })
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
        Finalize-Job 'Cancelled'
        Set-Status 'Inventario finalizado. No se ha convertido ningún libro.'
        Update-RecoveryState
        return
    }
    Start-ConversionPhase
}

function Start-ConversionPhase {
    if ($script:Total -eq 0) {
        Finalize-Job 'Completed'
        [System.Windows.MessageBox]::Show('No se han encontrado EPUB que cumplan los filtros.', 'BookForge', 'OK', 'Information') | Out-Null
        return
    }
    $script:Index = 0
    $script:Converted = 0
    $script:Skipped = 0
    $script:Failed = 0
    $script:FinishedCount = 0
    $script:LateSkipped = 0
    $script:AttemptedCount = 0
    $script:ActiveSeconds = 0.0
    $script:PendingToConvert = if ([bool]$script:Manifest.Settings.SkipExisting) { [Math]::Max(0, $script:Total - $script:InventoryExisting) } else { $script:Total }
    $script:VerifyCandidates.Clear()
    $script:VerifySeen = 0
    $script:VerificationFailed = 0
    $script:VerificationPassed = 0
    $script:PauseRequested = $false
    $script:WorkerLimit = [int]$script:Manifest.Settings.ParallelCount
    $script:Phase = 'Convert'
    $script:RunMode = 'New'
    $script:IsRunning = $true
    $script:ConversionTimer.Restart()
    $script:LastCheckpointAt = Get-Date
    if ($script:JournalWriter) { $script:JournalWriter.Flush() }
    Set-ManifestStatus 'Running'
    $script:Timer.Start()
    $script:ui.PauseButton.Content = 'Pausar'
    $script:ui.PauseButton.IsEnabled = $true
    $script:ui.StartButton.IsEnabled = $false
    $script:ui.ResumeButton.IsEnabled = $false
    Set-InputLock $true
    $script:ui.DuplicateButton.IsEnabled = $false
    $script:ui.ProgressBar.IsIndeterminate = $false
    $script:ui.ProgressBar.Value = 0
    $script:ui.ProgressCaption.Text = 'CONVERSIÓN'
    $script:ui.ProgressPercent.Text = '0 %'
    $script:ui.IncludedLabel.Text = "$($script:Total) EPUB preparados · $(Get-EffectiveWorkerLimit) procesos simultáneos previstos"
    $script:ui.ActiveValue.Text = '0 / 0'
    Set-Status 'Iniciando conversiones…'
    if ([bool]$script:Manifest.Settings.NightMode) { Set-KeepAwake $true }
    $script:LastCpuCheck = [DateTime]::MinValue
    $script:LastUiUpdate = [DateTime]::MinValue
}

function Start-ResumeJob {
    if (-not $script:ConverterPath -or -not (Test-Path -LiteralPath $script:ConverterPath -PathType Leaf)) { $script:ConverterPath = Find-EbookConvert }
    if (-not $script:ConverterPath) { [System.Windows.MessageBox]::Show('No se encuentra Calibre. Instálalo y vuelve a intentar.', 'Calibre', 'OK', 'Warning') | Out-Null; return }
    if (-not $script:Recovery) { Update-RecoveryState }
    if (-not $script:Recovery) { return }
    $manifestPath = [string]$script:Recovery.Path
    $manifest = Read-JsonFile $manifestPath
    if (-not $manifest -or -not (Test-Path -LiteralPath ([string]$manifest.InventoryPath) -PathType Leaf)) {
        [System.Windows.MessageBox]::Show('El inventario guardado no está disponible. Inicia un inventario nuevo.', 'No se puede reanudar', 'OK', 'Warning') | Out-Null
        Update-RecoveryState
        return
    }
    if (-not ([string]$manifest.Root).Equals((Normalize-RootPath $script:ui.RootPathBox.Text.Trim()), [System.StringComparison]::OrdinalIgnoreCase)) {
        [System.Windows.MessageBox]::Show('La carpeta raíz no coincide con el trabajo guardado.', 'No se puede reanudar', 'OK', 'Warning') | Out-Null
        return
    }
    $savedSettings = $manifest.Settings
    $preferredTheme = $script:ThemeName
    Apply-Settings $savedSettings
    if ($preferredTheme -in @('Dark', 'Light')) { Set-Theme $preferredTheme }
    $script:RootPath = [string]$manifest.Root
    $script:RootKey = [string]$manifest.RootKey
    $script:JobDir = Split-Path -Parent $manifestPath
    $script:ManifestPath = $manifestPath
    $script:Manifest = $manifest
    $script:InventoryPath = [string]$manifest.InventoryPath
    $script:JournalPath = [string]$manifest.JournalPath
    $script:PreflightReportPath = if ($manifest.PreflightReportPath) { [string]$manifest.PreflightReportPath } else { Join-Path $script:JobDir 'preflight.json' }
    $script:ErrorLogPath = if ($manifest.ErrorLogPath) { [string]$manifest.ErrorLogPath } else { Join-Path $script:JobDir 'errors.jsonl' }
    $script:FailedPathsPath = if ($manifest.FailedPathsPath) { [string]$manifest.FailedPathsPath } else { Join-Path $script:JobDir 'failed.txt' }
    $script:FailedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $script:FailedPathsPath -PathType Leaf) { foreach ($failedPath in [System.IO.File]::ReadLines($script:FailedPathsPath)) { if ($failedPath) { [void]$script:FailedPaths.Add($failedPath) } } }
    $script:ReportPath = [string]$manifest.ReportPath
    $script:Files = [System.Collections.Generic.List[object]]::new()
    $script:InventoryExisting = 0
    $recoveredStates = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($script:JournalPath -and (Test-Path -LiteralPath $script:JournalPath -PathType Leaf)) {
        try {
            Import-Csv -LiteralPath $script:JournalPath -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
                $loggedPath = [string]$_.'EPUB'
                if ($loggedPath -and [System.IO.Path]::GetExtension($loggedPath).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $recoveredStates[$loggedPath] = [string]$_.Estado
                }
            }
        } catch {
            $recoveredStates.Clear()
        }
    }
    $recoveredConverted = 0
    $recoveredSkipped = 0
    $recoveredDone = [System.Collections.Generic.List[object]]::new()
    $recoveredPending = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($line in [System.IO.File]::ReadLines($script:InventoryPath)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $outputPath = [System.IO.Path]::ChangeExtension($line, '.mobi')
                $outputExists = $false
                $outputLength = [long]0
                if ([System.IO.File]::Exists($outputPath)) { try { $outputLength = [long]([System.IO.FileInfo]::new($outputPath).Length); $outputExists = $outputLength -gt 0 } catch {} }
                if ($outputExists) { $script:InventoryExisting++ }
                $lastState = if ($recoveredStates.ContainsKey($line)) { [string]$recoveredStates[$line] } else { '' }
                $recoveryKind = ''
                if ($outputExists -and $lastState -in @('OK', 'OK_REPLACED')) {
                    $recoveryKind = 'Converted'
                    $recoveredConverted++
                } elseif ($outputExists -and $lastState -in @('SKIPPED_EXISTS', 'SKIPPED_RACE', 'RECOVERED_SKIPPED')) {
                    $recoveryKind = 'Skipped'
                    $recoveredSkipped++
                } elseif ($outputExists -and [bool]$savedSettings.SkipExisting) {
                    $recoveryKind = 'Skipped'
                    $recoveredSkipped++
                }
                $item = [pscustomobject]@{ Path = $line; Length = [long]0; OutputExists = $outputExists; OutputLength = $outputLength; RecoveryKind = $recoveryKind }
                if ($recoveryKind) { $recoveredDone.Add($item) }
                else { $recoveredPending.Add($item) }
            }
        }
    } catch {
        [System.Windows.MessageBox]::Show("No se pudo leer el inventario: $($_.Exception.Message)", 'Error al reanudar', 'OK', 'Error') | Out-Null
        return
    }
    foreach ($item in $recoveredPending) { $script:Files.Add($item) }
    $pendingFiles = $script:Files
    $script:Files = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $recoveredDone) { $script:Files.Add($item) }
    foreach ($item in $pendingFiles) { $script:Files.Add($item) }
    if ($script:Files.Count -eq 0) {
        [System.Windows.MessageBox]::Show('El inventario no contiene EPUB accesibles.', 'No se puede reanudar', 'OK', 'Information') | Out-Null
        return
    }
    $answer = Show-ThemedYesNo -message "Se reanudará el trabajo guardado con $($script:Files.Count) rutas inventariadas. Las salidas identificadas como completadas se conservarán. Las rutas pendientes respetarán la opción de omitir o reemplazar MOBI existentes guardada en el trabajo.`r`n`r`n¿Continuar?" -title 'Reanudar trabajo' -kind 'Question' -defaultYes $false
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    foreach ($item in $recoveredDone) { Remove-FailedPath ([string]$item.Path) }
    if ($script:FailedListChanges -gt 0) { try { Save-FailedPathList; $script:FailedListChanges = 0 } catch {} }
    $script:Total = $script:Files.Count
    $script:Index = $recoveredDone.Count
    $script:Converted = $recoveredConverted
    $script:Skipped = $recoveredSkipped
    $script:Failed = 0
    $script:FinishedCount = $recoveredDone.Count
    $script:LateSkipped = 0
    $script:AttemptedCount = $recoveredConverted
    $script:ActiveSeconds = 0.0
    $script:ElapsedPriorSeconds = [double]$manifest.ElapsedSeconds
    $script:ConversionPriorSeconds = [double]$manifest.ConversionSeconds
    $script:PendingToConvert = [Math]::Max(0, $script:Total - $recoveredSkipped)
    $script:ScanWarnings = 0
    $script:ActiveJobs = [System.Collections.Generic.List[object]]::new()
    $script:JournalWriter = [System.IO.StreamWriter]::new($script:JournalPath, $true, [System.Text.UTF8Encoding]::new($true))
    $script:JournalRowsSinceFlush = 0
    $script:FailedListChanges = 0
    $script:PauseRequested = $false
    $script:RunMode = 'Resume'
    $script:RunTimer.Restart()
    $script:LastCheckpointAt = Get-Date
    $script:ConversionTimer.Restart()
    $script:IsRunning = $true
    $script:Phase = 'Convert'
    $script:WorkerLimit = [int]$savedSettings.ParallelCount
    $script:ActivityItems.Clear()
    Load-ErrorHistory $script:ErrorLogPath
    Update-PreflightReportCard
    $script:VerifyCandidates.Clear()
    $script:VerifySeen = 0
    $script:VerificationFailed = if ($manifest.Stats -and $null -ne $manifest.Stats.VerificationFailed) { [int]$manifest.Stats.VerificationFailed } else { 0 }
    $script:VerificationPassed = if ($manifest.Stats -and $null -ne $manifest.Stats.VerificationPassed) { [int]$manifest.Stats.VerificationPassed } else { 0 }
    if ($null -ne $manifest.VerifySeen) { $script:VerifySeen = [int]$manifest.VerifySeen }
    foreach ($verifyPath in @($manifest.VerifyCandidates)) { if (-not [string]::IsNullOrWhiteSpace([string]$verifyPath)) { $script:VerifyCandidates.Add([string]$verifyPath) } }
    $script:DiskPauseTriggered = $false
    $script:LastDiskCheck = [DateTime]::MinValue
    $script:ui.StartButton.IsEnabled = $false
    $script:ui.ResumeButton.IsEnabled = $false
    $script:ui.PauseButton.IsEnabled = $true
    Set-InputLock $true
    $script:ui.DuplicateButton.IsEnabled = $false
    $script:ui.ProgressBar.IsIndeterminate = $false
    $script:ui.ProgressBar.Value = 0
    $script:ui.ProgressCaption.Text = 'CONVERSIÓN'
    $resumePercent = if ($script:Total -gt 0) { [int][Math]::Floor(($script:FinishedCount / [double]$script:Total) * 100) } else { 0 }
    $script:ui.ProgressPercent.Text = "$resumePercent %"
    $script:ui.ProgressBar.Value = $resumePercent
    $script:ui.PauseButton.Content = 'Pausar'
    $script:ui.IncludedLabel.Text = "$($script:Total) EPUB recuperados del inventario guardado"
    Set-Status 'Reanudando trabajo…'
    Add-Activity -State 'RESUME' -Path $script:RootPath -Detail 'Se ha reanudado un trabajo guardado.'
    $script:Timer.Start()
    if ([bool]$savedSettings.NightMode) { Set-KeepAwake $true }
    Set-ManifestStatus 'Running'
}

function Get-EffectiveWorkerLimit {
    $settings = $script:Manifest.Settings
    $selected = [Math]::Max(1, [Math]::Min($script:LogicalProcessors, [int]$settings.ParallelCount))
    if ([bool]$settings.AutoParallel) {
        $selected = [Math]::Min(4, [Math]::Max(1, [int][Math]::Floor($script:LogicalProcessors / 4.0)))
        if ($script:CpuUsage -ge 0 -and $script:CpuUsage -ge 80) { $selected = 1 }
        elseif ($script:CpuUsage -ge 0 -and $script:CpuUsage -ge 55) { $selected = [Math]::Min(2, $selected) }
        if ($script:MemoryUsage -ge 90) { $selected = 1 }
        elseif ($script:MemoryUsage -ge 82) { $selected = [Math]::Min(2, $selected) }
    }
    if ([bool]$settings.LowImpact) {
        $selected = [Math]::Min(2, $selected)
        if (($script:CpuUsage -ge 65) -or ($script:MemoryUsage -ge 88)) { $selected = 1 }
    }
    return [Math]::Max(1, $selected)
}

function Update-CpuUsage {
    if (((Get-Date) - $script:LastCpuCheck).TotalSeconds -lt 8) { return }
    $script:LastCpuCheck = Get-Date
    try {
        $sample = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop
        if ($sample) { $script:CpuUsage = [double]$sample.PercentProcessorTime }
    } catch { $script:CpuUsage = -1.0 }
    try {
        $memory = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $totalKb = [double]$memory.TotalVisibleMemorySize
        $freeKb = [double]$memory.FreePhysicalMemory
        if ($totalKb -gt 0) { $script:MemoryUsage = [Math]::Max(0, [Math]::Min(100, (1.0 - ($freeKb / $totalKb)) * 100.0)) }
    } catch { $script:MemoryUsage = -1.0 }
    $cpuText = if ($script:CpuUsage -ge 0) { ('{0:N0} %' -f $script:CpuUsage) } else { '—' }
    $memoryText = if ($script:MemoryUsage -ge 0) { ('{0:N0} %' -f $script:MemoryUsage) } else { '—' }
    $script:ui.CpuLabel.Text = "CPU: $($script:LogicalProcessors) lógicos · uso $cpuText · RAM $memoryText"
}

function Test-MobiStructure([string]$path, [bool]$deep) {
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if ($stream.Length -lt 86) { return [pscustomobject]@{ Valid = $false; Detail = 'El archivo es demasiado pequeño para ser un MOBI válido.' } }
        $header = New-Object byte[] 86
        $read = 0
        while ($read -lt $header.Length) {
            $count = $stream.Read($header, $read, $header.Length - $read)
            if ($count -le 0) { break }
            $read += $count
        }
        if ($read -lt $header.Length) { return [pscustomobject]@{ Valid = $false; Detail = 'Cabecera MOBI incompleta.' } }
        $type = [System.Text.Encoding]::ASCII.GetString($header, 60, 4)
        $creator = [System.Text.Encoding]::ASCII.GetString($header, 64, 4)
        if ($type -ne 'BOOK' -or $creator -ne 'MOBI') { return [pscustomobject]@{ Valid = $false; Detail = "Cabecera de base de datos no reconocida ($type/$creator)." } }
        $recordCount = ([int]$header[76] -shl 8) -bor [int]$header[77]
        $directoryBytes = [long]$recordCount * 8
        $tableEnd = 78 + $directoryBytes
        if ($recordCount -lt 1 -or $tableEnd -gt $stream.Length) { return [pscustomobject]@{ Valid = $false; Detail = "Tabla de registros no válida: $recordCount registros declarados." } }
        if ($deep) {
            if ($tableEnd -gt $stream.Length -or $tableEnd -gt [int]::MaxValue) { return [pscustomobject]@{ Valid = $false; Detail = 'La tabla de registros excede el tamaño del archivo.' } }
            $stream.Position = 78
            $directory = New-Object byte[] ([int]$directoryBytes)
            $got = 0
            while ($got -lt $directory.Length) {
                $count = $stream.Read($directory, $got, $directory.Length - $got)
                if ($count -le 0) { break }
                $got += $count
            }
            if ($got -ne $directory.Length) { return [pscustomobject]@{ Valid = $false; Detail = 'Tabla de registros incompleta.' } }
            $previous = [long]$tableEnd
            for ($i = 0; $i -lt $recordCount; $i++) {
                $offset = [long]([uint32]$directory[$i * 8] * 16777216 + [uint32]$directory[$i * 8 + 1] * 65536 + [uint32]$directory[$i * 8 + 2] * 256 + [uint32]$directory[$i * 8 + 3])
                if ($offset -lt $previous -or $offset -ge $stream.Length) { return [pscustomobject]@{ Valid = $false; Detail = "Offset de registro inválido en la posición $i." } }
                $previous = $offset
            }
            $firstRecordOffset = [long]([uint32]$directory[0] * 16777216 + [uint32]$directory[1] * 65536 + [uint32]$directory[2] * 256 + [uint32]$directory[3])
            if (($firstRecordOffset + 20) -gt $stream.Length) { return [pscustomobject]@{ Valid = $false; Detail = 'El primer registro no contiene una cabecera MOBI completa.' } }
            $stream.Position = $firstRecordOffset + 16
            $marker = New-Object byte[] 4
            $markerRead = 0
            while ($markerRead -lt $marker.Length) {
                $count = $stream.Read($marker, $markerRead, $marker.Length - $markerRead)
                if ($count -le 0) { break }
                $markerRead += $count
            }
            if ($markerRead -ne 4 -or [System.Text.Encoding]::ASCII.GetString($marker) -ne 'MOBI') { return [pscustomobject]@{ Valid = $false; Detail = 'El primer registro no contiene el identificador MOBI esperado.' } }
        }
        return [pscustomobject]@{ Valid = $true; Detail = $(if ($deep) { "Estructura verificada; $recordCount registros." } else { 'Cabecera MOBI correcta.' }) }
    } catch {
        return [pscustomobject]@{ Valid = $false; Detail = $_.Exception.Message }
    } finally { if ($stream) { $stream.Dispose() } }
}

function Set-KeepAwake([bool]$enabled) {
    try {
        [void][BookForge.PowerPolicy]::KeepAwake($enabled)
        $script:PowerAwake = $enabled
    } catch { $script:PowerAwake = $false }
}

function Notify-User([string]$title, [string]$message) {
    if ([bool]$script:ui.NotificationsCheck.IsChecked -and $script:NotificationIcon) {
        try { $script:NotificationIcon.BalloonTipTitle = $title; $script:NotificationIcon.BalloonTipText = $message; $script:NotificationIcon.ShowBalloonTip(8000) } catch {}
    }
    if ([bool]$script:ui.SoundCheck.IsChecked) { try { [System.Media.SystemSounds]::Asterisk.Play() } catch {} }
}

function Register-VerifyCandidate([string]$path) {
    $limit = [int]$script:Manifest.Settings.VerifyCount
    if ($limit -le 0) { return }
    $script:VerifySeen++
    if ($script:VerifyCandidates.Count -lt $limit) { $script:VerifyCandidates.Add($path); return }
    $index = $script:VerifyRandom.Next(0, $script:VerifySeen)
    if ($index -lt $limit) { $script:VerifyCandidates[$index] = $path }
}

function Invoke-ExtendedVerification {
    $limit = [int]$script:Manifest.Settings.VerifyCount
    if ($limit -le 0 -or $script:VerifyCandidates.Count -eq 0) { return }
    $script:ui.StatusLabel.Text = 'Verificando una muestra de MOBI…'
    foreach ($path in $script:VerifyCandidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $script:VerificationFailed++
            Write-Journal 'VERIFY_ERROR' $path $path 'La salida ha desaparecido antes de la verificación ampliada.'
            continue
        }
        $result = Test-MobiStructure $path $true
        if ($result.Valid) {
            $script:VerificationPassed++
            Write-Journal 'VERIFY_OK' $path $path $result.Detail
        } else {
            $script:VerificationFailed++
            Write-Journal 'VERIFY_ERROR' $path $path $result.Detail
        }
    }
}

function Start-ConversionProcess($item) {
    $inputPath = [string]$item.Path
    $outputPath = [System.IO.Path]::ChangeExtension($inputPath, '.mobi')
    $skipExisting = [bool]$script:Manifest.Settings.SkipExisting
    if ($skipExisting -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        try {
            $existing = Get-Item -LiteralPath $outputPath -ErrorAction Stop
            if ($existing.Length -gt 0) {
                $script:Skipped++
                $script:FinishedCount++
                if (-not [bool]$item.OutputExists) { $script:LateSkipped++ }
                Remove-FailedPath $inputPath
                Write-Journal 'SKIPPED_EXISTS' $inputPath $outputPath 'Se ha conservado un MOBI existente con contenido.'
                return
            }
        } catch {
            $script:Failed++
            $script:FinishedCount++
            $script:AttemptedCount++
            Write-Journal 'ERROR_OUTPUT_CHECK' $inputPath $outputPath $_.Exception.Message
            return
        }
    }
    $tempPath = Join-Path ([System.IO.Path]::GetDirectoryName($inputPath)) ('.bookforge_' + [Guid]::NewGuid().ToString('N') + '.mobi')
    $process = $null
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $script:ConverterPath
        $psi.Arguments = '"' + $inputPath + '" "' + $tempPath + '" --output-profile kindle'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw 'No se pudo iniciar ebook-convert.exe.' }
        try { if ([bool]$script:Manifest.Settings.LowImpact) { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } } catch {}
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $script:ActiveJobs.Add([pscustomobject]@{ Input = $inputPath; Output = $outputPath; Temp = $tempPath; Process = $process; OutTask = $outTask; ErrTask = $errTask; Started = [DateTime]::Now; OutputExistedAtScan = [bool]$item.OutputExists })
        Add-Activity -State 'STARTED' -Path $inputPath -Detail 'Conversión iniciada.'
    } catch {
        $script:Failed++
        $script:FinishedCount++
        $script:AttemptedCount++
        Write-Journal 'ERROR_START' $inputPath $outputPath $_.Exception.Message
        if ($process) { try { if (-not $process.HasExited) { $process.Kill() } } catch {}; try { $process.Dispose() } catch {} }
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-AvailableConversions {
    if ($script:PauseRequested) { return }
    if ($script:Index -lt $script:Total -and -not $script:DiskPauseTriggered -and (((Get-Date) - $script:LastDiskCheck).TotalSeconds -ge 15)) {
        $script:LastDiskCheck = Get-Date
        $freeBytes = Get-DriveFreeBytes $script:RootPath
        if ($freeBytes -ge 0 -and $freeBytes -lt 134217728) {
            $script:DiskPauseTriggered = $true
            $script:PauseRequested = $true
            Set-Status 'Pausa de seguridad: queda menos de 128 MB libres. Las conversiones activas terminarán y podrás liberar espacio.'
            Notify-User 'BookForge: poco espacio en disco' 'Se ha solicitado una pausa de seguridad porque quedan menos de 128 MB libres.'
            Add-Activity -State 'DISK_SPACE_PAUSE' -Path $script:RootPath -Detail 'Pausa de seguridad por menos de 128 MB disponibles.'
            return
        }
    }
    Update-CpuUsage
    $effective = Get-EffectiveWorkerLimit
    $script:ActiveJobCount = $script:ActiveJobs.Count
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $checked = 0
    while (-not $script:PauseRequested -and $script:Index -lt $script:Total -and $script:ActiveJobs.Count -lt $effective -and $checked -lt 100 -and $sw.ElapsedMilliseconds -lt 40) {
        $item = $script:Files[$script:Index]
        $script:Index++
        $checked++
        Start-ConversionProcess $item
    }
}

function Complete-ReadyConversions {
    for ($i = $script:ActiveJobs.Count - 1; $i -ge 0; $i--) {
        $job = $script:ActiveJobs[$i]
        $process = $job.Process
        try {
            if (-not $process.HasExited) { continue }
            if (-not $job.OutTask.IsCompleted -or -not $job.ErrTask.IsCompleted) { continue }
            $exitCode = $process.ExitCode
            $duration = [Math]::Max(0.01, ((Get-Date) - $job.Started).TotalSeconds)
            $script:ActiveSeconds += $duration
            $script:AttemptedCount++
            $stdout = $job.OutTask.GetAwaiter().GetResult()
            $stderr = $job.ErrTask.GetAwaiter().GetResult()
            $process.Dispose()
            $detail = ''
            $outputCreated = $false
            try {
                $tempInfo = Get-Item -LiteralPath $job.Temp -ErrorAction SilentlyContinue
                if ($exitCode -ne 0 -or -not $tempInfo -or $tempInfo.Length -le 0) {
                    $messages = @($stderr -split "`r?`n") + @($stdout -split "`r?`n")
                    $messages = @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8)
                    $detail = "Calibre devolvió el código $exitCode. " + ($messages -join ' | ')
                    if ([string]::IsNullOrWhiteSpace($detail.Trim())) { $detail = 'Calibre no generó una salida válida.' }
                    throw $detail
                }
                $basic = Test-MobiStructure $job.Temp $false
                if (-not $basic.Valid) { throw "La salida no supera la comprobación estructural: $($basic.Detail)" }
                if (Test-Path -LiteralPath $job.Output -PathType Leaf) {
                    $existingInfo = Get-Item -LiteralPath $job.Output -ErrorAction Stop
                    if ([bool]$script:Manifest.Settings.SkipExisting -and $existingInfo.Length -gt 0) {
                        Remove-Item -LiteralPath $job.Temp -Force -ErrorAction SilentlyContinue
                        $script:Skipped++
                        if (-not [bool]$job.OutputExistedAtScan) { $script:LateSkipped++ }
                        Remove-FailedPath $job.Input
                        Write-Journal 'SKIPPED_RACE' $job.Input $job.Output 'La salida apareció durante la conversión; no se sobrescribió.'
                    } else {
                        $backup = Join-Path ([System.IO.Path]::GetDirectoryName($job.Input)) ('.bookforge_backup_' + [Guid]::NewGuid().ToString('N') + '.mobi')
                        [System.IO.File]::Replace($job.Temp, $job.Output, $backup, $true)
                        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                        $script:Converted++
                        $outputCreated = $true
                        Remove-FailedPath $job.Input
                        Write-Journal 'OK_REPLACED' $job.Input $job.Output 'Conversión completada y salida sustituida de forma segura.'
                    }
                } else {
                    [System.IO.File]::Move($job.Temp, $job.Output)
                    $script:Converted++
                    $outputCreated = $true
                    Remove-FailedPath $job.Input
                    Write-Journal 'OK' $job.Input $job.Output $basic.Detail
                }
                if ($outputCreated -and [int]$script:Manifest.Settings.VerifyCount -gt 0 -and (Test-Path -LiteralPath $job.Output -PathType Leaf)) { Register-VerifyCandidate $job.Output }
            } catch {
                $script:Failed++
                if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $_.Exception.Message }
                Write-Journal 'ERROR' $job.Input $job.Output $detail
            } finally {
                if (Test-Path -LiteralPath $job.Temp -PathType Leaf) { Remove-Item -LiteralPath $job.Temp -Force -ErrorAction SilentlyContinue }
            }
            $script:FinishedCount++
            [void]$script:ActiveJobs.RemoveAt($i)
        } catch {
            $script:Failed++
            $script:FinishedCount++
            Write-Journal 'ERROR_MONITOR' $job.Input $job.Output $_.Exception.Message
            try { if ($process -and -not $process.HasExited) { $process.Kill() } } catch {}
            try { if ($process) { $process.Dispose() } } catch {}
            try { if (Test-Path -LiteralPath $job.Temp) { Remove-Item -LiteralPath $job.Temp -Force -ErrorAction SilentlyContinue } } catch {}
            [void]$script:ActiveJobs.RemoveAt($i)
        }
    }
}

function Update-ProgressDisplay {
    $total = [Math]::Max(1, $script:Total)
    $completed = [Math]::Min($script:Total, $script:FinishedCount)
    $percent = [int][Math]::Floor(($completed / [double]$total) * 100)
    $script:ui.ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $percent))
    $script:ui.ConvertedValue.Text = $script:Converted.ToString('N0')
    $script:ui.SkippedValue.Text = $script:Skipped.ToString('N0')
    $script:ui.FailedValue.Text = $script:Failed.ToString('N0')
    $script:ui.PendingValue.Text = [Math]::Max(0, $script:PendingToConvert - ($script:Converted + $script:Failed + $script:LateSkipped)).ToString('N0')
    $elapsed = $script:ElapsedPriorSeconds + $script:RunTimer.Elapsed.TotalSeconds
    $conversionElapsed = $script:ConversionPriorSeconds + $script:ConversionTimer.Elapsed.TotalSeconds
    $rate = if ($conversionElapsed -gt 0) { $script:AttemptedCount / ($conversionElapsed / 60.0) } else { 0 }
    $script:ui.RateValue.Text = ('{0:N1} libros/min' -f $rate)
    $script:ui.ElapsedValue.Text = Format-Duration $elapsed
    $pendingActual = [Math]::Max(0, $script:PendingToConvert - ($script:Converted + $script:Failed + $script:LateSkipped))
    if ($script:AttemptedCount -ge 3 -and $rate -gt 0) {
        $etaSeconds = [Math]::Max(0, $pendingActual * 60.0 / $rate)
        $script:CurrentEta = Format-Duration $etaSeconds
    } else { $script:CurrentEta = 'Calculando…' }
    $script:ui.EtaValue.Text = $script:CurrentEta
    $script:ui.ProgressPercent.Text = "$percent %"
    $currentLimit = Get-EffectiveWorkerLimit
    $script:ui.ActiveValue.Text = "$($script:ActiveJobs.Count) / $currentLimit"
    $script:ui.ScanWarnValue.Text = $script:ScanWarnings.ToString('N0')
}

function Finish-Pause {
    $script:Timer.Stop()
    Set-KeepAwake $false
    if ($script:JournalWriter) { $script:JournalWriter.Flush(); $script:JournalWriter.Dispose(); $script:JournalWriter = $null }
    Set-ManifestStatus 'Paused'
    $script:RunTimer.Stop()
    $script:ConversionTimer.Stop()
    $script:Phase = 'Paused'
    $script:IsRunning = $false
    $script:PauseRequested = $false
    $script:ui.PauseButton.IsEnabled = $false
    $script:ui.StartButton.IsEnabled = $true
    Set-InputLock $false
    $script:ui.DuplicateButton.IsEnabled = $true
    $script:ui.ResumeButton.IsEnabled = $true
    $script:ui.ProgressBar.IsIndeterminate = $false
    if ($script:DiskPauseTriggered) { Set-Status 'Pausa de seguridad por falta de espacio. Libera espacio y reanuda el trabajo.' } else { Set-Status 'Trabajo pausado de forma segura. Puedes cerrar la aplicación o reanudarlo.' }
    Add-Activity -State 'PAUSED' -Path $script:RootPath -Detail 'Estado guardado; las conversiones activas han terminado.'
    Update-RecoveryState
    if ($script:CloseWhenPaused) { $script:CloseWhenPaused = $false; $script:Window.Close() }
}

function Finalize-Job([string]$status, [string]$fatalDetail = '') {
    $script:Timer.Stop()
    Dispose-Enumerators
    if ($status -eq 'Completed' -and [int]$script:Manifest.Settings.VerifyCount -gt 0) { Invoke-ExtendedVerification }
    Set-KeepAwake $false
    if ($script:JournalWriter) {
        try { $script:JournalWriter.Flush(); $script:JournalWriter.Dispose() } catch {}
        $script:JournalWriter = $null
    }
    foreach ($job in @($script:ActiveJobs.ToArray())) {
        try { if ($job.Process -and -not $job.Process.HasExited) { $job.Process.Kill() } } catch {}
        try { if ($job.Process) { $job.Process.Dispose() } } catch {}
        try { if ($job.Temp -and (Test-Path -LiteralPath $job.Temp)) { Remove-Item -LiteralPath $job.Temp -Force -ErrorAction SilentlyContinue } } catch {}
    }
    $script:ActiveJobs.Clear()
    $script:RunTimer.Stop()
    $script:ConversionTimer.Stop()
    $script:Phase = 'Idle'
    $script:IsRunning = $false
    $script:PauseRequested = $false
    $script:ui.StartButton.IsEnabled = $true
    Set-InputLock $false
    $script:ui.PauseButton.IsEnabled = $false
    $script:ui.PauseButton.Content = 'Pausar'
    $script:ui.DuplicateButton.IsEnabled = $true
    $script:ui.ProgressBar.IsIndeterminate = $false
    $canRetry = $script:FailedPathsPath -and (Test-Path -LiteralPath $script:FailedPathsPath -PathType Leaf) -and ((Get-Item -LiteralPath $script:FailedPathsPath -ErrorAction SilentlyContinue).Length -gt 0)
    $script:ui.RetryButton.IsEnabled = [bool]$canRetry
    $script:ui.RetryErrorsButton.IsEnabled = [bool]$canRetry
    if ($status -eq 'Completed') { $script:ui.ProgressBar.Value = 100 }
    Set-ManifestStatus $status
    $fullLibraryEstimateSeconds = $null
    $fullLibraryEstimateText = ''
    if ($status -eq 'Completed' -and $script:RunMode -eq 'New' -and [string]$script:Manifest.Settings.TestMode -match '^(20|100|500)$' -and [long]$script:Manifest.AllFound -gt $script:Total) {
        $fullCount = [long]$script:Manifest.AllFound
        $fullPending = if ([bool]$script:Manifest.Settings.SkipExisting) { [Math]::Max(0, $fullCount - [long]$script:Manifest.AllPreExistingMobi) } else { $fullCount }
        if ($script:Converted -ge 3 -and $script:AttemptedCount -gt 0 -and $script:ConversionTimer.Elapsed.TotalSeconds -gt 0) {
            $fullLibraryEstimateSeconds = [Math]::Round($fullPending * ($script:ConversionTimer.Elapsed.TotalSeconds / $script:AttemptedCount), 2)
            $fullLibraryEstimateText = "`r`nEstimación orientativa para la biblioteca completa: $(Format-Duration $fullLibraryEstimateSeconds), calculada con la muestra y la configuración actuales."
        } else {
            $fullLibraryEstimateText = "`r`nLa muestra no ha generado suficientes conversiones correctas para estimar con confianza el tiempo de toda la biblioteca. Prueba con una muestra mayor."
        }
    }
    $summary = [pscustomobject]@{
        JobId = $script:Manifest.JobId
        Root = $script:RootPath
        Status = $status
        Created = [string]$script:Manifest.Created
        GeneratedAt = (Get-Date).ToString('o')
        Finished = (Get-Date).ToString('o')
        Total = $script:Total
        Converted = $script:Converted
        Skipped = $script:Skipped
        Failed = $script:Failed
        VerificationPassed = $script:VerificationPassed
        VerificationFailed = $script:VerificationFailed
        Warnings = $script:ScanWarnings
        ElapsedSeconds = [Math]::Round($script:ElapsedPriorSeconds + $script:RunTimer.Elapsed.TotalSeconds, 2)
        ConversionSeconds = [Math]::Round($script:ConversionPriorSeconds + $script:ConversionTimer.Elapsed.TotalSeconds, 2)
        FullLibraryEstimateSeconds = $fullLibraryEstimateSeconds
        Eta = $script:CurrentEta
        Errors = $fatalDetail
        Journal = $script:JournalPath
        Inventory = $script:InventoryPath
    }
    try { Write-JsonAtomic $script:ReportPath $summary } catch {}
    $script:ui.ReportPathLabel.Text = $script:ReportPath
    if ($fatalDetail) {
        Set-Status 'El trabajo se detuvo por un error. Revisa los detalles.'
        Add-ErrorEntry -State 'FATAL' -Path $script:RootPath -Detail $fatalDetail
        Add-Activity -State 'FATAL' -Path $script:RootPath -Detail $fatalDetail
        [System.Windows.MessageBox]::Show("El trabajo se detuvo por un error:`r`n$fatalDetail`r`n`r`nSe conservaron los archivos ya completados.", 'Error de BookForge', 'OK', 'Error') | Out-Null
    } elseif ($status -eq 'Completed') {
        Set-Status 'Conversión terminada.'
        Add-Activity -State 'COMPLETED' -Path $script:RootPath -Detail 'Trabajo terminado.'
        Notify-User 'BookForge ha terminado' "Convertidos: $($script:Converted). Omitidos: $($script:Skipped). Errores: $($script:Failed)."
        $message = "Trabajo terminado.`r`n`r`nEncontrados en este trabajo: $($script:Total)`r`nConvertidos: $($script:Converted)`r`nOmitidos: $($script:Skipped)`r`nFallidos: $($script:Failed)`r`nVerificación ampliada: $($script:VerificationPassed) correctos, $($script:VerificationFailed) con incidencias`r`nAvisos de inventario: $($script:ScanWarnings)`r`nTiempo transcurrido: $(Format-Duration ($script:ElapsedPriorSeconds + $script:RunTimer.Elapsed.TotalSeconds))$fullLibraryEstimateText`r`n`r`nInforme: $script:ReportPath`r`nRegistro: $script:JournalPath"
        [System.Windows.MessageBox]::Show($message, 'BookForge', 'OK', $(if ($script:Failed -gt 0 -or $script:ScanWarnings -gt 0 -or $script:VerificationFailed -gt 0) { 'Warning' } else { 'Information' })) | Out-Null
        if ([bool]$script:Manifest.Settings.Shutdown -and $script:Total -gt 0) {
            $shutdownAnswer = Show-ThemedYesNo -message 'Has activado el apagado al terminar. ¿Quieres programar el apagado de Windows dentro de 60 segundos? Puedes cancelarlo con "shutdown /a".' -title 'Apagado al terminar' -kind 'Warning' -defaultYes $false
            if ($shutdownAnswer -eq [System.Windows.MessageBoxResult]::Yes) {
                Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\shutdown.exe') -ArgumentList '/s /t 60 /c "BookForge ha terminado"' -WindowStyle Hidden
            }
        }
    } elseif ($status -eq 'Cancelled') {
        Set-Status 'Trabajo cancelado antes de convertir.'
    } elseif ($status -eq 'ScanStopped') {
        Set-Status 'Inventario detenido. No se ha convertido ningún libro.'
    } else { Set-Status "Trabajo guardado: $status." }
    Update-RecoveryState
    Save-Preferences
}

function Stop-RequestedWork {
    if ($script:Phase -eq 'Scan') {
        $script:PauseRequested = $true
        $script:Timer.Stop()
        Dispose-Enumerators
        Set-KeepAwake $false
        if ($script:JournalWriter) { $script:JournalWriter.Flush(); $script:JournalWriter.Dispose(); $script:JournalWriter = $null }
        Set-ManifestStatus 'ScanStopped'
        $script:IsRunning = $false
        $script:Phase = 'Idle'
        $script:ui.StartButton.IsEnabled = $true
        Set-InputLock $false
        $script:ui.PauseButton.IsEnabled = $false
        $script:ui.DuplicateButton.IsEnabled = $true
        $script:ui.ProgressBar.IsIndeterminate = $false
        $script:ui.ProgressPercent.Text = '—'
        $script:ui.ProgressCaption.Text = 'INVENTARIO DETENIDO'
        $script:ui.IncludedLabel.Text = "Inventario detenido · $($script:Files.Count.ToString('N0')) EPUB encontrados · $($script:DirectoriesSeen.ToString('N0')) carpetas recorridas"
        $script:ui.RateValue.Text = 'Detenido'
        $script:ui.EtaValue.Text = '—'
        Set-Status 'Inventario detenido; no se ha convertido ningún libro.'
        Update-RecoveryState
        if ($script:CloseWhenPaused) { $script:CloseWhenPaused = $false; $script:Window.Close() }
        return
    }
    $script:PauseRequested = $true
    $script:ui.PauseButton.IsEnabled = $false
    Set-Status "Pausa solicitada. Se están terminando $($script:ActiveJobs.Count) conversiones activas…"
    Add-Activity -State 'PAUSE_REQUESTED' -Path $script:RootPath -Detail 'Se ha solicitado una pausa segura.'
    if ($script:ActiveJobs.Count -eq 0) { Finish-Pause }
}

function Start-DuplicateAnalysis {
    if ($script:IsRunning -or $script:DuplicateMode) { return }
    $root = $script:ui.RootPathBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        [System.Windows.MessageBox]::Show('Selecciona una carpeta raíz para analizar.', 'Carpeta necesaria', 'OK', 'Warning') | Out-Null
        return
    }
    $script:RootPath = Normalize-RootPath $root
    try {
        $includePatternsToCheck = Get-PatternList $script:ui.IncludePatternsBox.Text
        $excludePatternsToCheck = Get-PatternList $script:ui.ExcludePatternsBox.Text
        Test-FilterPatterns -patterns $includePatternsToCheck -label 'inclusión'
        Test-FilterPatterns -patterns $excludePatternsToCheck -label 'exclusión'
    } catch {
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'Filtro no válido', 'OK', 'Warning') | Out-Null
        return
    }
    $scanOptions = "Carpeta: $script:RootPath`r`nIncluir: $(if ([string]::IsNullOrWhiteSpace($script:ui.IncludePatternsBox.Text)) { 'Todos los EPUB' } else { $script:ui.IncludePatternsBox.Text })`r`nExcluir: $(if ([string]::IsNullOrWhiteSpace($script:ui.ExcludePatternsBox.Text)) { 'Ninguna' } else { $script:ui.ExcludePatternsBox.Text })`r`n`r`nSe leerán los EPUB para detectar copias idénticas byte por byte. No se convertirá, moverá ni borrará ningún archivo. El análisis puede tardar y usar bastante lectura de disco.`r`n`r`n¿Iniciar el análisis?"
    $confirmScan = Show-ThemedYesNo -message $scanOptions -title 'Opciones del análisis de duplicados' -kind 'Question' -defaultYes $false
    if ($confirmScan -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $script:RootKey = Get-RootKey $script:RootPath
    $base = Join-Path (Join-Path $script:JobsRoot $script:RootKey) 'DuplicateReports'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $id = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $script:DuplicateWorkDir = Join-Path $base $id
    New-Item -ItemType Directory -Path $script:DuplicateWorkDir -Force | Out-Null
    $script:DuplicateProgressPath = Join-Path $script:DuplicateWorkDir 'progress.json'
    $script:DuplicateCancelPath = Join-Path $script:DuplicateWorkDir 'cancel.flag'
    $script:LastDuplicateReport = Join-Path $script:DuplicateWorkDir 'duplicates.csv'
    $script:ui.OpenDuplicateReportButton.IsEnabled = $false
    $script:ui.OpenDuplicateFolderButton.IsEnabled = $false
    $errorPath = Join-Path $script:DuplicateWorkDir 'worker_error.txt'
    $workerPath = Join-Path $PSScriptRoot 'BookForge_Duplicates.ps1'
    if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
        [System.Windows.MessageBox]::Show('Falta BookForge_Duplicates.ps1. Comprueba que has descomprimido todos los archivos.', 'Archivo auxiliar', 'OK', 'Error') | Out-Null
        return
    }
    $include = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:ui.IncludePatternsBox.Text))
    $exclude = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:ui.ExcludePatternsBox.Text))
    $rootB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:RootPath))
    $workB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:DuplicateWorkDir))
    $progressB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:DuplicateProgressPath))
    $cancelB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script:DuplicateCancelPath))
    $errorB64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($errorPath))
    $powerShellPath = Join-Path $PSHOME 'powershell.exe'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $workerPath + '"'), '-RootB64', $rootB64, '-WorkDirB64', $workB64, '-IncludeB64', $include, '-ExcludeB64', $exclude, '-ProgressB64', $progressB64, '-CancelB64', $cancelB64, '-ErrorB64', $errorB64)
    $argumentLine = ($arguments -join ' ')
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $powerShellPath
        $psi.Arguments = $argumentLine
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $psi
        if (-not $process.Start()) { throw 'No se pudo iniciar el análisis de duplicados.' }
        $script:DuplicateProcess = $process
        $script:DuplicateStartedAt = Get-Date
        $script:DuplicateMode = $true
        $script:ui.StartButton.IsEnabled = $false
        $script:ui.ResumeButton.IsEnabled = $false
        Set-InputLock $true
        $script:ui.PauseButton.IsEnabled = $false
        $script:ui.DuplicateButton.Content = 'Cancelar análisis'
        $script:ui.DuplicateButton.IsEnabled = $true
        $script:ui.ProgressBar.IsIndeterminate = $true
        $script:ui.ProgressPercent.Text = '—'
        Set-Status 'Analizando duplicados exactos; no se modificará ningún libro.'
        $script:ui.DuplicateReportLabel.Text = $script:DuplicateWorkDir
        $script:Timer.Start()
        Add-Activity -State 'DUPLICATE_SCAN_START' -Path $script:RootPath -Detail 'Análisis independiente de duplicados iniciado.'
    } catch {
        $script:DuplicateMode = $false
        $script:ui.StartButton.IsEnabled = $true
        $script:ui.ResumeButton.IsEnabled = [bool]$script:ResumeAvailable
        Set-InputLock $false
        $script:ui.DuplicateButton.Content = 'Analizar duplicados'
        [System.Windows.MessageBox]::Show("No se pudo iniciar el análisis: $($_.Exception.Message)", 'Error', 'OK', 'Error') | Out-Null
    }
}

function Cancel-DuplicateAnalysis {
    if (-not $script:DuplicateMode) { return }
    try { [System.IO.File]::WriteAllText($script:DuplicateCancelPath, 'cancel', [System.Text.Encoding]::ASCII) } catch {}
    Set-Status 'Solicitud de cancelación del análisis de duplicados…'
    $script:ui.DuplicateButton.IsEnabled = $false
}

function Complete-DuplicateAnalysis {
    $script:DuplicateMode = $false
    $script:Timer.Stop()
    $script:ui.StartButton.IsEnabled = $true
    Set-InputLock $false
    $script:ui.DuplicateButton.IsEnabled = $true
    $script:ui.DuplicateButton.Content = 'Analizar duplicados'
    $script:ui.ProgressBar.IsIndeterminate = $false
    if ($script:DuplicateProcess) { try { $script:DuplicateProcess.Dispose() } catch {}; $script:DuplicateProcess = $null }
    Update-RecoveryState
    $progress = Read-JsonFile $script:DuplicateProgressPath
    if (Test-Path -LiteralPath (Join-Path $script:DuplicateWorkDir 'worker_error.txt') -PathType Leaf) {
        $err = Get-Content -LiteralPath (Join-Path $script:DuplicateWorkDir 'worker_error.txt') -Raw -ErrorAction SilentlyContinue
        Set-Status 'El análisis de duplicados ha terminado con un error.'
        [System.Windows.MessageBox]::Show("Error durante el análisis:`r`n$err`r`n`r`nCarpeta del informe: $script:DuplicateWorkDir", 'Análisis de duplicados', 'OK', 'Error') | Out-Null
        if ($script:CloseWhenDuplicateFinishes) { $script:CloseWhenDuplicateFinishes = $false; $script:Window.Close() }
        return
    }
    if (-not $progress) {
        Set-Status 'El análisis ha finalizado sin resumen disponible.'
        if ($script:CloseWhenDuplicateFinishes) { $script:CloseWhenDuplicateFinishes = $false; $script:Window.Close() }
        return
    }
    if ($progress.Status -eq 'Cancelled') {
        Set-Status 'Análisis de duplicados cancelado.'
        [System.Windows.MessageBox]::Show("Análisis cancelado. Los archivos no se han modificado.`r`n`r`nDatos parciales: $script:DuplicateWorkDir", 'Duplicados', 'OK', 'Information') | Out-Null
        if ($script:CloseWhenDuplicateFinishes) { $script:CloseWhenDuplicateFinishes = $false; $script:Window.Close() }
        return
    }
    if ($progress.Status -ne 'Completed' -or -not (Test-Path -LiteralPath ([string]$progress.ReportPath) -PathType Leaf)) {
        Set-Status 'El análisis de duplicados no se ha completado.'
        [System.Windows.MessageBox]::Show("El proceso terminó sin generar un informe completo. Comprueba el contenido de esta carpeta:`r`n$script:DuplicateWorkDir", 'Análisis incompleto', 'OK', 'Warning') | Out-Null
        if ($script:CloseWhenDuplicateFinishes) { $script:CloseWhenDuplicateFinishes = $false; $script:Window.Close() }
        return
    }
    $script:LastDuplicateReport = [string]$progress.ReportPath
    $script:ui.DuplicateReportLabel.Text = $script:LastDuplicateReport
    $script:ui.OpenDuplicateReportButton.IsEnabled = Test-Path -LiteralPath $script:LastDuplicateReport -PathType Leaf
    $script:ui.OpenDuplicateFolderButton.IsEnabled = Test-Path -LiteralPath $script:DuplicateWorkDir -PathType Container
    Set-Status 'Análisis de duplicados completado. No se ha borrado ni modificado ningún archivo.'
    $reportMessage = "Análisis terminado`r`n`r`nFecha y hora del informe: $($progress.ReportCreatedAt)`r`nEPUB examinados: $($progress.FilesScanned)`r`nGrupos de duplicados exactos: $($progress.DuplicateGroups)`r`nArchivos en grupos duplicados: $($progress.DuplicateFiles)`r`nCopias redundantes: $($progress.RedundantCopies)`r`nEspacio potencial recuperable: $(Format-Bytes ([long]$progress.PotentialSavings))`r`nAvisos de lectura: $($progress.Warnings)`r`n`r`nNo se ha borrado ni modificado ningún archivo.`r`nInforme CSV: $($progress.ReportPath)`r`n`r`n¿Quieres abrir el informe ahora?"
    Add-Activity -State 'DUPLICATE_SCAN_COMPLETE' -Path $script:RootPath -Detail "$($progress.DuplicateGroups) grupos de duplicados exactos encontrados."
    $answer = Show-ThemedYesNo -message $reportMessage -title 'Informe de duplicados' -kind 'Information' -defaultYes $false
    if ($answer -eq [System.Windows.MessageBoxResult]::Yes -and (Test-Path -LiteralPath $script:LastDuplicateReport -PathType Leaf)) { Start-Process -FilePath $script:LastDuplicateReport }
    if ($script:CloseWhenDuplicateFinishes) { $script:CloseWhenDuplicateFinishes = $false; $script:Window.Close() }
}

function Tick-Main {
    try {
        if ($script:DuplicateMode) {
            $progress = Read-JsonFile $script:DuplicateProgressPath
            if ($progress) {
                $script:ui.ProgressBar.IsIndeterminate = $false
                if ([string]$progress.Phase -eq 'Completed') {
                    $script:ui.ProgressBar.Value = 100
                    $script:ui.ProgressPercent.Text = '100 %'
                } elseif ([int]$progress.TotalFiles -gt 0 -and $progress.Phase -eq 'Hashing') {
                    $value = [int][Math]::Floor(([double]$progress.HashedFiles / [Math]::Max(1, [double]$progress.TotalFiles)) * 100)
                    $script:ui.ProgressBar.Value = [Math]::Max(0, [Math]::Min(100, $value))
                    $script:ui.ProgressPercent.Text = "$value %"
                } elseif ($progress.Phase -eq 'Scanning') {
                    $script:ui.ProgressBar.IsIndeterminate = $true
                    $script:ui.ProgressPercent.Text = '—'
                }
                $elapsed = if ($script:DuplicateStartedAt) { Format-Duration ((Get-Date) - $script:DuplicateStartedAt).TotalSeconds } else { '—' }
                Set-Status "Duplicados: $($progress.Phase) · elementos revisados $($progress.EntriesScanned) · EPUB $($progress.FilesScanned) · hashes $($progress.HashedFiles) · tiempo $elapsed"
            }
            if ($script:DuplicateProcess -and $script:DuplicateProcess.HasExited) { Complete-DuplicateAnalysis }
            return
        }
        if ($script:IsRunning -and $script:Phase -eq 'Convert' -and (((Get-Date) - $script:LastCheckpointAt).TotalSeconds -ge 15)) {
            try { Set-ManifestStatus 'Running'; $script:LastCheckpointAt = Get-Date } catch {}
        }
        if ($script:Phase -eq 'Scan') {
            if ($script:PauseRequested) { Stop-RequestedWork; return }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $worked = 0
            while ($worked -lt 1200 -and $sw.ElapsedMilliseconds -lt 40) {
                if ([string]::IsNullOrEmpty($script:CurrentScanDirectory)) {
                    if (-not (Begin-ScanDirectory)) { Finish-Inventory; return }
                    $worked++
                    continue
                }
                if ($script:ScanMode -eq 'Files') {
                    if ($null -eq $script:FileEnumerator) { $script:ScanMode = 'Directories'; continue }
                    try {
                        if ($script:FileEnumerator.MoveNext()) {
                            $path = [string]$script:FileEnumerator.Current
                            $script:ScanEntries++
                            $worked++
                            if ([System.IO.Path]::GetExtension($path).Equals('.epub', [StringComparison]::OrdinalIgnoreCase)) {
                                try {
                                    $fileAttributes = [System.IO.File]::GetAttributes($path)
                                    if (($fileAttributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and (Test-SelectedPath $path $script:RootPath $script:IncludePatterns $script:ExcludePatterns)) {
                                        $info = [System.IO.FileInfo]::new($path)
                                        $sourceLength = [long]$info.Length
                                        $script:InventoryAllBytes += $sourceLength
                                        $outputPath = [System.IO.Path]::ChangeExtension($path, '.mobi')
                                        $outputExists = $false
                                        $outputLength = [long]0
                                        if ([System.IO.File]::Exists($outputPath)) {
                                            try { $outInfo = [System.IO.FileInfo]::new($outputPath); $outputLength = [long]$outInfo.Length; $outputExists = $outputLength -gt 0; if ($outputExists) { $script:InventoryAllExisting++; $script:InventoryAllMatchedInputBytes += $sourceLength; $script:InventoryAllOutputBytes += $outputLength } } catch { $script:ScanWarnings++ }
                                        }
                                        $script:Files.Add([pscustomobject]@{ Path = $path; Length = $sourceLength; OutputExists = $outputExists; OutputLength = $outputLength })
                                    }
                                } catch {
                                    $script:ScanWarnings++
                                    Write-Journal 'SCAN_WARNING' $path '' $_.Exception.Message
                                }
                            }
                        } else {
                            try { $script:FileEnumerator.Dispose() } catch {}
                            $script:FileEnumerator = $null
                            $script:ScanMode = 'Directories'
                        }
                    } catch {
                        $script:ScanWarnings++
                        Write-Journal 'SCAN_WARNING' $script:CurrentScanDirectory '' $_.Exception.Message
                        try { $script:FileEnumerator.Dispose() } catch {}
                        $script:FileEnumerator = $null
                        $script:ScanMode = 'Directories'
                    }
                    continue
                }
                if ($script:ScanMode -eq 'Directories') {
                    if ($null -eq $script:DirectoryEnumerator) {
                        try { $script:DirectoryEnumerator = ([System.IO.Directory]::EnumerateDirectories($script:CurrentScanDirectory, '*', [System.IO.SearchOption]::TopDirectoryOnly)).GetEnumerator() }
                        catch {
                            $script:ScanWarnings++
                            Write-Journal 'SCAN_WARNING' $script:CurrentScanDirectory '' $_.Exception.Message
                            $script:CurrentScanDirectory = ''
                            $script:ScanMode = 'Files'
                            continue
                        }
                    }
                    try {
                        if ($script:DirectoryEnumerator.MoveNext()) {
                            $subdir = [string]$script:DirectoryEnumerator.Current
                            $worked++
                            try {
                                $attributes = [System.IO.File]::GetAttributes($subdir)
                                if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 -and -not (Test-ExcludedDirectory $subdir $script:RootPath $script:ExcludePatterns)) { $script:ScanStack.Push($subdir) }
                            } catch {
                                $script:ScanWarnings++
                                Write-Journal 'SCAN_WARNING' $subdir '' $_.Exception.Message
                            }
                        } else {
                            try { $script:DirectoryEnumerator.Dispose() } catch {}
                            $script:DirectoryEnumerator = $null
                            $script:CurrentScanDirectory = ''
                            $script:ScanMode = 'Files'
                        }
                    } catch {
                        $script:ScanWarnings++
                        Write-Journal 'SCAN_WARNING' $script:CurrentScanDirectory '' $_.Exception.Message
                        try { $script:DirectoryEnumerator.Dispose() } catch {}
                        $script:DirectoryEnumerator = $null
                        $script:CurrentScanDirectory = ''
                        $script:ScanMode = 'Files'
                    }
                }
            }
            if (((Get-Date) - $script:LastUiUpdate).TotalMilliseconds -ge 350) {
                $script:ui.ProgressBar.IsIndeterminate = $true
                $script:ui.ProgressBar.Value = 0
                $script:ui.ProgressCaption.Text = 'INVENTARIO'
                $script:ui.ProgressPercent.Text = '…'
                $script:ui.IncludedLabel.Text = "Inventario en curso · $($script:Files.Count.ToString('N0')) EPUB encontrados · $($script:DirectoriesSeen.ToString('N0')) carpetas recorridas"
                $script:ui.ScanWarnValue.Text = $script:ScanWarnings.ToString('N0')
                $script:ui.ConvertedValue.Text = '—'; $script:ui.SkippedValue.Text = '—'; $script:ui.FailedValue.Text = '—'; $script:ui.PendingValue.Text = '—'
                $script:ui.ElapsedValue.Text = Format-Duration $script:RunTimer.Elapsed.TotalSeconds
                $script:ui.RateValue.Text = 'Buscando EPUB…'
                $script:ui.EtaValue.Text = 'Calculando inventario…'
                $script:LastUiUpdate = Get-Date
            }
            return
        }
        if ($script:Phase -eq 'Convert') {
            Complete-ReadyConversions
            Update-ProgressDisplay
            if ($script:PauseRequested) {
                if ($script:ActiveJobs.Count -eq 0) { Finish-Pause; return }
                Set-Status "Pausa solicitada · terminando $($script:ActiveJobs.Count) conversiones activas…"
                return
            }
            Start-AvailableConversions
            Update-ProgressDisplay
            if ($script:Index -ge $script:Total -and $script:ActiveJobs.Count -eq 0) {
                Finalize-Job 'Completed'
                return
            }
            if ($script:ActiveJobs.Count -gt 0) {
                $activeNames = @($script:ActiveJobs | Select-Object -First 3 | ForEach-Object { [System.IO.Path]::GetFileName($_.Input) }) -join ' · '
                Set-Status "Convirtiendo · $($script:FinishedCount.ToString('N0')) / $($script:Total.ToString('N0')) · $($script:ActiveJobs.Count) activos · $activeNames"
            } else {
                Set-Status "Revisando cola · $($script:Index.ToString('N0')) / $($script:Total.ToString('N0'))"
            }
            return
        }
    } catch {
        $detail = $_.Exception.ToString()
        try { Write-Journal 'FATAL' $script:RootPath '' $detail } catch {}
        Finalize-Job 'Interrupted' $detail
    }
}

function Open-CurrentReport {
    $path = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ReportPath) -and (Test-Path -LiteralPath $script:ReportPath -PathType Leaf)) { $path = $script:ReportPath }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$script:JournalPath) -and (Test-Path -LiteralPath $script:JournalPath -PathType Leaf)) { $path = $script:JournalPath }
    if (-not $path) { [System.Windows.MessageBox]::Show('Todavía no hay un informe disponible.', 'Informes', 'OK', 'Information') | Out-Null; return }
    Start-Process -FilePath $path
}

function Retry-FailedFiles([string[]]$OnlyPaths = @()) {
    if ($script:IsRunning) { return }
    $failedFile = $script:FailedPathsPath
    if (-not $failedFile -and $script:Manifest -and $script:Manifest.FailedPathsPath) { $failedFile = [string]$script:Manifest.FailedPathsPath }
    $paths = @()
    if ($failedFile -and (Test-Path -LiteralPath $failedFile -PathType Leaf)) { $paths = @([System.IO.File]::ReadLines($failedFile) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique) }
    if ($OnlyPaths -and $OnlyPaths.Count -gt 0) { $pathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase); foreach ($p in $OnlyPaths) { [void]$pathSet.Add([string]$p) }; $paths = @($paths | Where-Object { $pathSet.Contains([string]$_) }) }
    if ($paths.Count -eq 0) { [System.Windows.MessageBox]::Show('No hay archivos fallidos accesibles para reintentar.', 'Reintentar fallidos', 'OK', 'Information') | Out-Null; return }
    $answer = Show-ThemedYesNo -message "Se volverán a convertir $($paths.Count) EPUB fallidos. Una salida MOBI existente solo se sustituirá después de que Calibre genere y valide correctamente la nueva versión; si la conversión falla, la anterior se conservará.`r`n`r`n¿Continuar?" -title 'Reintentar fallidos' -kind 'Question' -defaultYes $false
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    $settings = Get-Settings
    $settings.SkipExisting = $false
    try { New-JobWorkspace $script:RootPath $settings } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Error', 'OK', 'Error') | Out-Null; return }
    $script:Files = [System.Collections.Generic.List[object]]::new()
    $script:InventoryExisting = 0
    foreach ($path in $paths) {
        try {
            $info = Get-Item -LiteralPath $path -ErrorAction Stop
            $outPath = [System.IO.Path]::ChangeExtension($path, '.mobi')
            $outLength = [long]0
            if ([System.IO.File]::Exists($outPath)) { try { $outLength = [long]([System.IO.FileInfo]::new($outPath).Length) } catch {} }
            $outExists = $outLength -gt 0
            $script:Files.Add([pscustomobject]@{ Path = $path; Length = [long]$info.Length; OutputExists = $outExists; OutputLength = $outLength })
            if ($outExists) { $script:InventoryExisting++ }
        } catch {}
    }
    $script:Total = $script:Files.Count
    $script:InventorySourceBytes = [long](($script:Files | Measure-Object -Property Length -Sum).Sum)
    $script:PendingToConvert = [Math]::Max(0, $script:Total - $script:InventoryExisting)
    $script:LateSkipped = 0
    $script:AttemptedCount = 0
    $script:ActiveSeconds = 0.0
    $script:ElapsedPriorSeconds = 0.0
    $script:ConversionPriorSeconds = 0.0
    $writer = [System.IO.StreamWriter]::new($script:InventoryPath, $false, [System.Text.UTF8Encoding]::new($false))
    try { foreach ($item in $script:Files) { $writer.WriteLine($item.Path) } } finally { $writer.Dispose() }
    $script:Manifest.Total = $script:Total
    $script:Manifest.InventoryBytes = $script:InventorySourceBytes
    $script:Manifest.Settings = $settings
    $script:VerifyCandidates.Clear()
    $script:VerifySeen = 0
    $script:VerificationFailed = 0
    $script:VerificationPassed = 0
    $script:RunTimer.Restart()
    $script:ConversionTimer.Reset()
    Set-ManifestStatus 'Ready'
    if ($script:Total -eq 0) { Finalize-Job 'Cancelled'; return }
    Start-ConversionPhase
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="BookForge 1.0 · EPUB a MOBI" Height="850" Width="1220" MinHeight="700" MinWidth="1000" WindowStartupLocation="CenterScreen" Background="{DynamicResource AppBackgroundBrush}" Foreground="{DynamicResource TextBrush}" FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="AppBackgroundBrush" Color="#0F172A" />
    <SolidColorBrush x:Key="PanelBrush" Color="#172033" />
    <SolidColorBrush x:Key="CardBrush" Color="#1E293B" />
    <SolidColorBrush x:Key="TextBrush" Color="#F8FAFC" />
    <SolidColorBrush x:Key="MutedBrush" Color="#94A3B8" />
    <SolidColorBrush x:Key="BorderBrush" Color="#334155" />
    <SolidColorBrush x:Key="InputBrush" Color="#0B1220" />
    <SolidColorBrush x:Key="AccentBrush" Color="#3B82F6" />
    <SolidColorBrush x:Key="GoodBrush" Color="#34D399" />
    <SolidColorBrush x:Key="WarnBrush" Color="#FBBF24" />
    <SolidColorBrush x:Key="BadBrush" Color="#F87171" />
    <Style TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="TextTrimming" Value="CharacterEllipsis"/><Setter Property="VerticalAlignment" Value="Center"/></Style>
    <Style TargetType="Button"><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Background" Value="{DynamicResource CardBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="13,8"/><Setter Property="Margin" Value="3"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.84"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.4"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="TextBox"><Setter Property="Background" Value="{DynamicResource InputBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="8,6"/><Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/><Setter Property="Margin" Value="2"/></Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="{DynamicResource InputBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="7,5"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="ItemContainerStyle">
        <Setter.Value>
          <Style TargetType="ComboBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
            <Setter Property="Background" Value="{DynamicResource InputBrush}"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="Template">
              <Setter.Value>
                <ControlTemplate TargetType="ComboBoxItem">
                  <Border x:Name="ItemBorder" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
                    <ContentPresenter VerticalAlignment="Center" RecognizesAccessKey="True" TextElement.Foreground="{TemplateBinding Foreground}"/>
                  </Border>
                  <ControlTemplate.Triggers>
                    <Trigger Property="IsHighlighted" Value="True">
                      <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource AccentBrush}"/>
                      <Setter Property="Foreground" Value="#FFFFFF"/>
                    </Trigger>
                    <Trigger Property="IsSelected" Value="True">
                      <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource CardBrush}"/>
                    </Trigger>
                  </ControlTemplate.Triggers>
                </ControlTemplate>
              </Setter.Value>
            </Setter>
          </Style>
        </Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                            IsChecked="{Binding Path=IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                            Background="{TemplateBinding Background}"
                            BorderBrush="{TemplateBinding BorderBrush}"
                            BorderThickness="{TemplateBinding BorderThickness}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                      <Grid>
                        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="26"/></Grid.ColumnDefinitions>
                        <Path Grid.Column="1" Data="M 0 0 L 4 4 L 8 0 Z" Fill="{DynamicResource MutedBrush}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                Margin="8,3,30,3" VerticalAlignment="Center" HorizontalAlignment="Left"
                                TextElement.Foreground="{TemplateBinding Foreground}"/>
              <Popup x:Name="Popup" Placement="Bottom"
                     IsOpen="{Binding Path=IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border x:Name="DropDownBorder" Background="{DynamicResource InputBrush}" BorderBrush="{DynamicResource BorderBrush}"
                        BorderThickness="1" CornerRadius="4" MaxHeight="{TemplateBinding MaxDropDownHeight}">
                  <ScrollViewer Margin="1" SnapsToDevicePixels="True">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="HasItems" Value="False"><Setter TargetName="DropDownBorder" Property="MinHeight" Value="26"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.6"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox"><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="Margin" Value="3,6"/><Setter Property="VerticalContentAlignment" Value="Center"/></Style>
    <Style TargetType="TabControl"><Setter Property="Background" Value="Transparent"/><Setter Property="BorderThickness" Value="0"/></Style>
    <Style TargetType="TabItem"><Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/><Setter Property="Background" Value="{DynamicResource PanelBrush}"/><Setter Property="Padding" Value="15,9"/><Setter Property="Margin" Value="2,2,2,0"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TabItem"><Border x:Name="TabBorder" Background="{TemplateBinding Background}" CornerRadius="7,7,0,0" Padding="{TemplateBinding Padding}"><ContentPresenter ContentSource="Header"/></Border><ControlTemplate.Triggers><Trigger Property="IsSelected" Value="True"><Setter TargetName="TabBorder" Property="Background" Value="{DynamicResource AccentBrush}"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
    <Style TargetType="DataGrid"><Setter Property="Background" Value="{DynamicResource PanelBrush}"/><Setter Property="Foreground" Value="{DynamicResource TextBrush}"/><Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="RowBackground" Value="{DynamicResource PanelBrush}"/><Setter Property="AlternatingRowBackground" Value="{DynamicResource CardBrush}"/><Setter Property="GridLinesVisibility" Value="Horizontal"/><Setter Property="HorizontalGridLinesBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="VerticalGridLinesBrush" Value="{DynamicResource BorderBrush}"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="CanUserAddRows" Value="False"/><Setter Property="AutoGenerateColumns" Value="False"/><Setter Property="EnableRowVirtualization" Value="True"/><Setter Property="EnableColumnVirtualization" Value="True"/><Setter Property="VirtualizingPanel.IsVirtualizing" Value="True"/><Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/><Setter Property="ScrollViewer.CanContentScroll" Value="True"/></Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{DynamicResource PanelBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
      <Setter Property="Padding" Value="9,7"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="7,4"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Background" Value="{DynamicResource InputBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource BorderBrush}"/>
      <Setter Property="Height" Value="8"/>
      <Setter Property="Margin" Value="2,4"/>
    </Style>
  </Window.Resources>
  <Grid Margin="18">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <Grid Grid.Row="0" Margin="0,0,0,12">
      <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <Border Width="48" Height="48" CornerRadius="12" Background="{DynamicResource AccentBrush}" Margin="0,0,12,0"><TextBlock Text="&#xE8A5;" FontFamily="Segoe MDL2 Assets" FontSize="24" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <StackPanel VerticalAlignment="Center"><TextBlock Text="BookForge" FontSize="25" FontWeight="Bold"/><TextBlock Text="Conversor local de EPUB a MOBI" Foreground="{DynamicResource MutedBrush}" FontSize="12"/></StackPanel>
      </StackPanel>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"><Border Background="{DynamicResource CardBrush}" CornerRadius="12" Padding="10,6" Margin="4"><TextBlock x:Name="CpuLabel" Text="CPU: detectando…" FontSize="11" Foreground="{DynamicResource MutedBrush}"/></Border><Button x:Name="ThemeButton" Content="Tema claro" MinWidth="105"/></StackPanel>
    </Grid>
    <Border Grid.Row="1" Background="{DynamicResource PanelBrush}" BorderBrush="{DynamicResource BorderBrush}" BorderThickness="1" CornerRadius="12" Padding="10" Margin="0,0,0,12">
      <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="17" Foreground="{DynamicResource AccentBrush}" Margin="4,0,10,0"/><TextBox x:Name="RootPathBox" Grid.Column="1" IsReadOnly="True" ToolTip="Carpeta raíz de la biblioteca"/><Button x:Name="BrowseButton" Grid.Column="2" Content="Elegir carpeta…"/></Grid>
    </Border>
    <TabControl x:Name="MainTabs" Grid.Row="2">
      <TabItem Header="Resumen">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="8">
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="12" Padding="16" Margin="0,0,0,12">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Biblioteca" FontSize="20" FontWeight="SemiBold"/><TextBlock x:Name="IncludedLabel" Text="Selecciona una carpeta para comenzar." Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,0"/><TextBlock x:Name="StatusLabel" Text="Listo." FontSize="13" FontWeight="SemiBold" Margin="0,10,0,0"/></StackPanel><Border Grid.Column="1" CornerRadius="10" Background="{DynamicResource CardBrush}" Padding="14" VerticalAlignment="Center"><StackPanel><TextBlock x:Name="ProgressCaption" Text="CONVERSIÓN" FontSize="10" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="ProgressPercent" Text="0 %" FontSize="27" FontWeight="Bold" HorizontalAlignment="Center"/></StackPanel></Border></Grid>
          </Border>
          <ProgressBar x:Name="ProgressBar" Height="10" Minimum="0" Maximum="100" Value="0" Margin="2,0,2,14" Background="{DynamicResource CardBrush}" Foreground="{DynamicResource AccentBrush}"/>
          <UniformGrid Columns="4" Rows="2" Margin="0,0,0,10">
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Convertidos" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="ConvertedValue" Text="0" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource GoodBrush}"/><TextBlock Text="MOBI creados" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Pendientes" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="PendingValue" Text="—" FontSize="24" FontWeight="SemiBold"/><TextBlock Text="Por procesar" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Omitidos" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="SkippedValue" Text="0" FontSize="24" FontWeight="SemiBold"/><TextBlock Text="Salida ya existente" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border x:Name="FailedCard" Focusable="True" IsHitTestVisible="True" Cursor="Hand" ToolTip="Abrir los errores y las opciones de reintento" Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Fallidos" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="FailedValue" Text="0" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource BadBrush}"/><TextBlock Text="Revisar errores" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Velocidad" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="RateValue" Text="—" FontSize="20" FontWeight="SemiBold"/><TextBlock Text="Libros por minuto" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Transcurrido" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="ElapsedValue" Text="0 s" FontSize="20" FontWeight="SemiBold"/><TextBlock Text="Trabajo actual" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Restante estimado" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="EtaValue" Text="—" FontSize="20" FontWeight="SemiBold"/><TextBlock Text="Estimación dinámica" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
            <Border Background="{DynamicResource CardBrush}" CornerRadius="10" Padding="13" Margin="3"><StackPanel><TextBlock Text="Activos" Foreground="{DynamicResource MutedBrush}"/><TextBlock x:Name="ActiveValue" Text="0" FontSize="20" FontWeight="SemiBold"/><TextBlock Text="Procesos Calibre" FontSize="10" Foreground="{DynamicResource MutedBrush}"/></StackPanel></Border>
          </UniformGrid>
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,10">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Recuperación" FontWeight="SemiBold"/><TextBlock x:Name="ResumeInfoLabel" Text="No hay un trabajo anterior pendiente." Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap" Margin="0,3,12,0"/></StackPanel><Button x:Name="ResumeButton" Grid.Column="1" Content="Reanudar trabajo" IsEnabled="False" VerticalAlignment="Center"/></Grid>
          </Border>
          <WrapPanel HorizontalAlignment="Left" Margin="-3,0,0,0">
            <Button x:Name="StartButton" Content="Iniciar conversión" Background="{DynamicResource AccentBrush}" Foreground="#FFFFFF" MinWidth="145" IsEnabled="False"/>
            <Button x:Name="PauseButton" Content="Pausar" IsEnabled="False" MinWidth="105"/>
            <Button x:Name="DuplicateButton" Content="Analizar duplicados" MinWidth="160"/>
            <Button x:Name="RetryButton" Content="Reintentar fallidos" IsEnabled="False" MinWidth="145"/>
          </WrapPanel>
        </StackPanel></ScrollViewer>
      </TabItem>
      <TabItem Header="Actividad">
        <Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid Grid.Row="0" Margin="0,0,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="260"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Actividad reciente" FontSize="18" FontWeight="SemiBold"/><TextBlock Text="Busca en las entradas recientes; el registro completo se guarda en CSV." Foreground="{DynamicResource MutedBrush}" FontSize="11"/></StackPanel><TextBox x:Name="ActivitySearchBox" Grid.Column="1" Height="32" VerticalAlignment="Center" ToolTip="Buscar por estado, archivo, ruta o detalle"/></Grid><DataGrid x:Name="ActivityGrid" Grid.Row="1" AlternationCount="2"><DataGrid.Columns><DataGridTextColumn Header="Hora" Binding="{Binding Time}" Width="90"/><DataGridTextColumn Header="Estado" Binding="{Binding State}" Width="150"/><DataGridTextColumn Header="Archivo" Binding="{Binding File}" Width="220"/><DataGridTextColumn Header="Detalle" Binding="{Binding Detail}" Width="*"/></DataGrid.Columns></DataGrid><TextBlock Grid.Row="2" Text="Máximo 600 entradas en memoria. El histórico completo está en el CSV del trabajo." Foreground="{DynamicResource MutedBrush}" Margin="2,7,2,0" FontSize="11"/></Grid>
      </TabItem>
      <TabItem Header="Errores">
        <Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid Grid.Row="0" Margin="0,0,0,7"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Errores y avisos" FontSize="18" FontWeight="SemiBold"/><TextBlock x:Name="ErrorCountLabel" Text="Entradas cargadas: 0" Foreground="{DynamicResource MutedBrush}" FontSize="11"/></StackPanel><TextBox x:Name="ErrorSearchBox" Grid.Column="1" Width="230" Height="32" VerticalAlignment="Center" ToolTip="Buscar por estado, archivo, ruta o detalle"/><Button x:Name="RetryErrorsButton" Grid.Column="2" Content="Reintentar todos" IsEnabled="False" VerticalAlignment="Center"/></Grid><DataGrid x:Name="ErrorGrid" Grid.Row="1" AlternationCount="2"><DataGrid.Columns><DataGridTextColumn Header="Fecha y hora" Binding="{Binding Time}" Width="155"/><DataGridTextColumn Header="Estado" Binding="{Binding State}" Width="125"/><DataGridTextColumn Header="Fase" Binding="{Binding Phase}" Width="95"/><DataGridTextColumn Header="Archivo" Binding="{Binding File}" Width="180"/><DataGridTextColumn Header="Ruta" Binding="{Binding Path}" Width="250"/><DataGridTextColumn Header="Detalle" Binding="{Binding Detail}" Width="*"/></DataGrid.Columns></DataGrid><WrapPanel Grid.Row="2" Margin="-3,7,0,2"><Button x:Name="RetrySelectedErrorButton" Content="Reintentar seleccionado" IsEnabled="False"/><Button x:Name="OpenSelectedErrorFolderButton" Content="Abrir ubicación" IsEnabled="False"/><Button x:Name="CopySelectedErrorButton" Content="Copiar detalles" IsEnabled="False"/></WrapPanel><TextBlock Grid.Row="3" Text="Se muestran hasta 2.000 entradas recientes; los registros completos y con fecha se conservan en el trabajo. Selecciona un error para ver acciones rápidas." Foreground="{DynamicResource MutedBrush}" Margin="2,5,2,0" FontSize="11"/></Grid>
      </TabItem>
      <TabItem Header="Informes">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="12"><TextBlock Text="Informes y registros" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/><Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,8"><StackPanel><TextBlock Text="Informe previo" FontWeight="SemiBold"/><TextBlock x:Name="PreflightReportLabel" Text="Todavía no hay un informe previo para este trabajo." TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,8"/><Button x:Name="OpenPreflightReportButton" Content="Abrir informe previo (JSON)" IsEnabled="False" HorizontalAlignment="Left"/></StackPanel></Border><Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,8"><StackPanel><TextBlock Text="Informe de trabajo" FontWeight="SemiBold"/><TextBlock x:Name="ReportPathLabel" Text="Aún no hay informe de trabajo." TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,8"/><WrapPanel><Button x:Name="OpenReportButton" Content="Abrir informe"/><Button x:Name="OpenJournalButton" Content="Abrir registro CSV"/><Button x:Name="OpenJobFolderButton" Content="Abrir carpeta del trabajo"/></WrapPanel></StackPanel></Border><Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12"><StackPanel><TextBlock Text="Informe de duplicados" FontWeight="SemiBold"/><TextBlock x:Name="DuplicateReportLabel" Text="Aún no se ha ejecutado un análisis de duplicados." TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,8"/><WrapPanel><Button x:Name="OpenDuplicateReportButton" Content="Abrir CSV de duplicados"/><Button x:Name="OpenDuplicateFolderButton" Content="Abrir carpeta del informe"/></WrapPanel></StackPanel></Border></StackPanel></ScrollViewer>
      </TabItem>
      <TabItem Header="Ajustes">
        <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="10">
          <TextBlock Text="Conversión y rendimiento" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,7"/>
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Conversiones simultáneas" FontWeight="SemiBold"/><TextBlock Text="El máximo depende de los procesadores lógicos detectados. Más procesos no siempre significa más velocidad." Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap" FontSize="11" Margin="0,3,8,0"/><CheckBox x:Name="AutoParallelCheck" Content="Modo automático prudente"/><CheckBox x:Name="LowImpactCheck" Content="Modo de bajo impacto mientras uso el PC"/><CheckBox x:Name="SkipExistingCheck" Content="Omitir MOBI existentes con contenido" IsChecked="True"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="Máximo manual"/><ComboBox x:Name="ParallelCombo"/><TextBlock Text="Modo de prueba" Margin="0,9,0,0"/><ComboBox x:Name="TestModeCombo"/><TextBlock Text="Verificación ampliada" Margin="0,9,0,0"/><ComboBox x:Name="VerifyCombo"/></StackPanel></Grid></Border>
          <TextBlock Text="Filtros de carpetas y archivos" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,7"/>
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,10"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel Margin="0,0,8,0"><TextBlock Text="Incluir patrones (opcional)" FontWeight="SemiBold"/><TextBlock Text="Uno por línea o separados por punto y coma. Ej.: Fantasía\*.epub" FontSize="10" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap"/><TextBox x:Name="IncludePatternsBox" Height="78" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/></StackPanel><StackPanel Grid.Column="1" Margin="8,0,0,0"><TextBlock Text="Excluir patrones" FontWeight="SemiBold"/><TextBlock Text="Ej.: *\Temporal\* o @Pruebas. Las carpetas @ se incluyen por defecto." FontSize="10" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap"/><TextBox x:Name="ExcludePatternsBox" Height="78" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/></StackPanel></Grid></Border>
          <TextBlock Text="Energía y avisos" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,7"/>
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12" Margin="0,0,0,10"><WrapPanel><CheckBox x:Name="NightModeCheck" Content="Evitar suspensión durante el trabajo"/><CheckBox x:Name="NotificationsCheck" Content="Notificaciones de Windows" IsChecked="True"/><CheckBox x:Name="SoundCheck" Content="Sonido al terminar"/><CheckBox x:Name="ShutdownCheck" Content="Preguntar si quiero apagar al terminar"/></WrapPanel></Border>
          <TextBlock Text="Perfiles" FontSize="18" FontWeight="SemiBold" Margin="0,0,0,7"/>
          <Border Background="{DynamicResource PanelBrush}" CornerRadius="10" Padding="12"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Nombre del perfil"/><TextBox x:Name="ProfileNameBox"/></StackPanel><StackPanel Grid.Column="1"><TextBlock Text="Cargar"/><ComboBox x:Name="ProfileCombo" Width="190"/></StackPanel><StackPanel Grid.Column="2" VerticalAlignment="Bottom" Orientation="Horizontal"><Button x:Name="SaveProfileButton" Content="Guardar perfil"/><Button x:Name="LoadProfileButton" Content="Aplicar perfil"/></StackPanel></Grid></Border>
          <TextBlock x:Name="ScanWarnValue" Text="0" Visibility="Collapsed"/>
        </StackPanel></ScrollViewer>
      </TabItem>
    </TabControl>
    <DockPanel Grid.Row="3" LastChildFill="True" Margin="2,10,2,0"><TextBlock Text="Los EPUB originales se conservan. Las conversiones se realizan localmente con Calibre." Foreground="{DynamicResource MutedBrush}" FontSize="11"/><TextBlock DockPanel.Dock="Right" Text="BookForge 1.0" Foreground="{DynamicResource MutedBrush}" FontSize="11" HorizontalAlignment="Right" Margin="20,0,0,0"/></DockPanel>
  </Grid>
</Window>
'@

try {
    $xmlReader = [System.Xml.XmlNodeReader]::new([xml]$xaml)
    $script:Window = [Windows.Markup.XamlReader]::Load($xmlReader)
} catch {
    $startupError = Join-Path $script:AppRoot 'StartupErrors.log'
    Add-Content -LiteralPath $startupError -Value ((Get-Date).ToString('o') + ' ' + $_.Exception.ToString())
    [System.Windows.Forms.MessageBox]::Show("No se pudo abrir BookForge. Detalle guardado en:`r`n$startupError`r`n`r`n$($_.Exception.Message)", 'BookForge', 'OK', 'Error') | Out-Null
    exit 1
}

$script:ui = @{}
foreach ($name in @('CpuLabel','ThemeButton','RootPathBox','BrowseButton','MainTabs','IncludedLabel','StatusLabel','ProgressCaption','ProgressPercent','ProgressBar','FailedCard','RetrySelectedErrorButton','OpenSelectedErrorFolderButton','CopySelectedErrorButton','PreflightReportLabel','OpenPreflightReportButton','ConvertedValue','PendingValue','SkippedValue','FailedValue','RateValue','ElapsedValue','EtaValue','ActiveValue','ResumeInfoLabel','ResumeButton','StartButton','PauseButton','DuplicateButton','RetryButton','ActivityGrid','ErrorGrid','ErrorCountLabel','RetryErrorsButton','ReportPathLabel','OpenReportButton','OpenJournalButton','OpenJobFolderButton','DuplicateReportLabel','OpenDuplicateReportButton','OpenDuplicateFolderButton','AutoParallelCheck','LowImpactCheck','SkipExistingCheck','ParallelCombo','TestModeCombo','VerifyCombo','IncludePatternsBox','ExcludePatternsBox','NightModeCheck','NotificationsCheck','SoundCheck','ShutdownCheck','ActivitySearchBox','ErrorSearchBox','ProfileNameBox','ProfileCombo','SaveProfileButton','LoadProfileButton','ScanWarnValue')) {
    $script:ui[$name] = $script:Window.FindName($name)
}
$script:ActivityItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$script:ErrorItems = [System.Collections.ObjectModel.ObservableCollection[object]]::new()
$script:ActivitySearch = ''
$script:ErrorSearch = ''
$script:VerifyCandidates = [System.Collections.Generic.List[string]]::new()
$script:VerifyRandom = [System.Random]::new()
$script:VerifySeen = 0
$script:VerificationFailed = 0
$script:VerificationPassed = 0
$script:FailedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$script:FailedPathsPath = ''
$script:IncludePatterns = @()
$script:ExcludePatterns = @()
$script:CloseWhenDuplicateFinishes = $false
$script:ActivityView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ActivityItems)
$script:ActivityView.Filter = {
    param($item)
    $query = [string]$script:ActivitySearch
    if ([string]::IsNullOrWhiteSpace($query)) { return $true }
    $searchable = '{0} {1} {2} {3} {4} {5}' -f $item.Time, $item.State, $item.Phase, $item.File, $item.Path, $item.Detail
    return $searchable.IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}
$script:ErrorView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:ErrorItems)
$script:ErrorView.Filter = {
    param($item)
    $query = [string]$script:ErrorSearch
    if ([string]::IsNullOrWhiteSpace($query)) { return $true }
    $searchable = '{0} {1} {2} {3} {4} {5}' -f $item.Time, $item.State, $item.Phase, $item.File, $item.Path, $item.Detail
    return $searchable.IndexOf($query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
}
$script:ui.ActivityGrid.ItemsSource = $script:ActivityView
$script:ui.ErrorGrid.ItemsSource = $script:ErrorView
$script:ui.ErrorGrid.Add_SelectionChanged({ Update-ErrorActionButtons })
$openFailedErrors = {
    $script:ui.MainTabs.SelectedIndex = 2
    $script:ui.ErrorSearchBox.Text = ''
    if ($script:ui.ErrorGrid.Items.Count -gt 0) {
        for ($i = $script:ui.ErrorGrid.Items.Count - 1; $i -ge 0; $i--) {
            $row = $script:ui.ErrorGrid.Items[$i]
            if ($row.Path -and ([string]$row.State -match 'ERROR|FAIL|FATAL') -and ([System.IO.Path]::GetExtension([string]$row.Path)).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)) {
                $script:ui.ErrorGrid.SelectedItem = $row
                $script:ui.ErrorGrid.ScrollIntoView($row)
                break
            }
        }
    }
    $script:ui.ErrorGrid.Focus()
}.GetNewClosure()
$script:ui.FailedCard.Add_PreviewMouseLeftButtonUp($openFailedErrors)
$script:ui.FailedCard.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter -or $e.Key -eq [System.Windows.Input.Key]::Space) {
        $e.Handled = $true
        $script:ui.MainTabs.SelectedIndex = 2
        $script:ui.ErrorSearchBox.Text = ''
        if ($script:ui.ErrorGrid.Items.Count -gt 0) {
            for ($i = $script:ui.ErrorGrid.Items.Count - 1; $i -ge 0; $i--) {
                $row = $script:ui.ErrorGrid.Items[$i]
                if ($row.Path -and ([string]$row.State -match 'ERROR|FAIL|FATAL') -and ([System.IO.Path]::GetExtension([string]$row.Path)).Equals('.epub', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $script:ui.ErrorGrid.SelectedItem = $row
                    $script:ui.ErrorGrid.ScrollIntoView($row)
                    break
                }
            }
        }
        $script:ui.ErrorGrid.Focus()
    }
})
$script:ui.CpuLabel.Text = "CPU: $($script:LogicalProcessors) procesadores lógicos"
$script:ConverterPath = Find-EbookConvert

for ($i = 1; $i -le $script:LogicalProcessors; $i++) { [void]$script:ui.ParallelCombo.Items.Add($i) }
$script:ui.ParallelCombo.SelectedItem = [Math]::Min(3, $script:LogicalProcessors)
foreach ($item in @('Biblioteca completa', '20', '100', '500')) { [void]$script:ui.TestModeCombo.Items.Add($item) }
$script:ui.TestModeCombo.SelectedItem = 'Biblioteca completa'
foreach ($item in @(0, 10, 25, 50)) { [void]$script:ui.VerifyCombo.Items.Add($item) }
$script:ui.VerifyCombo.SelectedItem = 0
$script:ui.StartButton.IsEnabled = $false
$script:ui.PauseButton.IsEnabled = $false
$script:ui.RetryButton.IsEnabled = $false
$script:ui.RetryErrorsButton.IsEnabled = $false
$script:ui.RetrySelectedErrorButton.IsEnabled = $false
$script:ui.OpenSelectedErrorFolderButton.IsEnabled = $false
$script:ui.CopySelectedErrorButton.IsEnabled = $false
$script:ui.OpenReportButton.IsEnabled = $false
$script:ui.OpenJournalButton.IsEnabled = $false
$script:ui.OpenJobFolderButton.IsEnabled = $false
$script:ui.OpenPreflightReportButton.IsEnabled = $false
$script:ui.OpenDuplicateReportButton.IsEnabled = $false
$script:ui.OpenDuplicateFolderButton.IsEnabled = $false
$script:ui.ReportPathLabel.Text = 'Aún no hay informe de trabajo.'
$script:ui.DuplicateReportLabel.Text = 'Aún no se ha ejecutado un análisis de duplicados.'
$script:ui.PreflightReportLabel.Text = 'Todavía no hay un informe previo para este trabajo.'

$script:FolderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
$script:FolderDialog.Description = 'Selecciona la raíz de la biblioteca que quieres procesar.'
$script:FolderDialog.ShowNewFolderButton = $false
$script:NotificationIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotificationIcon.Icon = [System.Drawing.SystemIcons]::Information
$script:NotificationIcon.Visible = $true
$script:NotificationIcon.Text = 'BookForge'
$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:Timer.Add_Tick({ Tick-Main })

$script:ui.BrowseButton.Add_Click({
    if ($script:IsRunning -or $script:DuplicateMode) { return }
    if ($script:ui.RootPathBox.Text -and (Test-Path -LiteralPath $script:ui.RootPathBox.Text -PathType Container)) { $script:FolderDialog.SelectedPath = $script:ui.RootPathBox.Text }
    if ($script:FolderDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:ui.RootPathBox.Text = $script:FolderDialog.SelectedPath
        $script:RootPath = $script:FolderDialog.SelectedPath
        $script:ui.StartButton.IsEnabled = $true
        Update-RecoveryState
        Save-Preferences
    }
})
$script:ui.StartButton.Add_Click({ Begin-NewScan })
$script:ui.ActivitySearchBox.Add_TextChanged({ $script:ActivitySearch = $script:ui.ActivitySearchBox.Text; if ($script:ActivityView) { $script:ActivityView.Refresh() } })
$script:ui.ErrorSearchBox.Add_TextChanged({ $script:ErrorSearch = $script:ui.ErrorSearchBox.Text; if ($script:ErrorView) { $script:ErrorView.Refresh() } })
$script:ui.ResumeButton.Add_Click({ Start-ResumeJob })
$script:ui.PauseButton.Add_Click({ if ($script:IsRunning) { Stop-RequestedWork } })
$script:ui.DuplicateButton.Add_Click({ if ($script:DuplicateMode) { Cancel-DuplicateAnalysis } else { Start-DuplicateAnalysis } })
$script:ui.RetryButton.Add_Click({ Retry-FailedFiles })
$script:ui.RetryErrorsButton.Add_Click({ Retry-FailedFiles })
$script:ui.RetrySelectedErrorButton.Add_Click({ if ($script:ui.ErrorGrid.SelectedItem) { Retry-FailedFiles -OnlyPaths @([string]$script:ui.ErrorGrid.SelectedItem.Path) } })
$script:ui.OpenSelectedErrorFolderButton.Add_Click({
    $selected = $script:ui.ErrorGrid.SelectedItem
    if ($selected -and $selected.Path) {
        $target = [string]$selected.Path
        if (Test-Path -LiteralPath $target -PathType Leaf) { $target = Split-Path -Parent $target }
        if (Test-Path -LiteralPath $target -PathType Container) { Start-Process explorer.exe -ArgumentList ('"' + $target + '"') }
    }
})
$script:ui.CopySelectedErrorButton.Add_Click({
    $selected = $script:ui.ErrorGrid.SelectedItem
    if ($selected) {
        $details = "Fecha: $($selected.Time)`r`nEstado: $($selected.State)`r`nFase: $($selected.Phase)`r`nArchivo: $($selected.File)`r`nRuta: $($selected.Path)`r`nDetalle: $($selected.Detail)"
        try { [System.Windows.Clipboard]::SetText($details) } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Portapapeles', 'OK', 'Warning') | Out-Null }
    }
})
$script:ui.SaveProfileButton.Add_Click({ Save-Profile })
$script:ui.LoadProfileButton.Add_Click({ Load-SelectedProfile })
$script:ui.ThemeButton.Add_Click({ if ($script:ThemeName -eq 'Dark') { Set-Theme 'Light' } else { Set-Theme 'Dark' } })
$script:ui.OpenReportButton.Add_Click({ Open-CurrentReport })
$script:ui.OpenPreflightReportButton.Add_Click({ if ($script:PreflightReportPath -and (Test-Path -LiteralPath $script:PreflightReportPath -PathType Leaf)) { Start-Process -FilePath $script:PreflightReportPath } else { [System.Windows.MessageBox]::Show('No hay un informe previo disponible.', 'Informes', 'OK', 'Information') | Out-Null } })
$script:ui.OpenJournalButton.Add_Click({ if (-not [string]::IsNullOrWhiteSpace([string]$script:JournalPath) -and (Test-Path -LiteralPath $script:JournalPath -PathType Leaf)) { Start-Process -FilePath $script:JournalPath } else { [System.Windows.MessageBox]::Show('No hay un registro CSV disponible.', 'Informes', 'OK', 'Information') | Out-Null } })
$script:ui.OpenJobFolderButton.Add_Click({ if ($script:JobDir -and (Test-Path -LiteralPath $script:JobDir)) { Start-Process explorer.exe -ArgumentList ('"' + $script:JobDir + '"') } })
$script:ui.OpenDuplicateReportButton.Add_Click({ if ($script:LastDuplicateReport -and (Test-Path -LiteralPath $script:LastDuplicateReport -PathType Leaf)) { Start-Process -FilePath $script:LastDuplicateReport } else { [System.Windows.MessageBox]::Show('No hay informe de duplicados disponible.', 'Informes', 'OK', 'Information') | Out-Null } })
$script:ui.OpenDuplicateFolderButton.Add_Click({ if ($script:DuplicateWorkDir -and (Test-Path -LiteralPath $script:DuplicateWorkDir)) { Start-Process explorer.exe -ArgumentList ('"' + $script:DuplicateWorkDir + '"') } })
function Update-RunningSetting([string]$name, $value) {
    if ($script:IsRunning -and $script:Manifest -and $script:Manifest.Settings) {
        $script:Manifest.Settings | Add-Member -MemberType NoteProperty -Name $name -Value $value -Force
        try { Set-ManifestStatus 'Running' } catch {}
        $script:LastCheckpointAt = Get-Date
    }
    Save-Preferences
}

$script:ui.RootPathBox.Add_LostFocus({
    $candidateRoot = $script:ui.RootPathBox.Text.Trim()
    $rootValid = -not [string]::IsNullOrWhiteSpace($candidateRoot) -and (Test-Path -LiteralPath $candidateRoot -PathType Container)
    $script:ui.StartButton.IsEnabled = [bool]$rootValid -and -not $script:IsRunning -and -not $script:DuplicateMode
    if ($rootValid) { try { $script:RootPath = Normalize-RootPath $candidateRoot } catch { $script:RootPath = $candidateRoot } }
    Save-Preferences
    Update-RecoveryState
})
$script:ui.AutoParallelCheck.Add_Click({ $script:ui.ParallelCombo.IsEnabled = -not [bool]$script:ui.AutoParallelCheck.IsChecked; Update-RunningSetting 'AutoParallel' ([bool]$script:ui.AutoParallelCheck.IsChecked) })
$script:ui.ParallelCombo.Add_SelectionChanged({ if ($script:ui.ParallelCombo.SelectedItem) { Update-RunningSetting 'ParallelCount' ([int]$script:ui.ParallelCombo.SelectedItem) } })
$script:ui.LowImpactCheck.Add_Click({
    $enabled = [bool]$script:ui.LowImpactCheck.IsChecked
    Update-RunningSetting 'LowImpact' $enabled
    foreach ($active in $script:ActiveJobs) { try { if ($enabled) { $active.Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal } else { $active.Process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal } } catch {} }
})
$script:ui.IncludePatternsBox.Add_LostFocus({ if ($script:IsRunning -and $script:Manifest.Settings) { $script:ui.IncludePatternsBox.Text = [string]$script:Manifest.Settings.IncludePatterns } else { Save-Preferences } })
$script:ui.ExcludePatternsBox.Add_LostFocus({ if ($script:IsRunning -and $script:Manifest.Settings) { $script:ui.ExcludePatternsBox.Text = [string]$script:Manifest.Settings.ExcludePatterns } else { Save-Preferences } })
$script:ui.NightModeCheck.Add_Click({
    $enabled = [bool]$script:ui.NightModeCheck.IsChecked
    if ($script:IsRunning) { Set-KeepAwake $enabled }
    Update-RunningSetting 'NightMode' $enabled
})
$script:ui.ShutdownCheck.Add_Click({ Update-RunningSetting 'Shutdown' ([bool]$script:ui.ShutdownCheck.IsChecked) })
$script:ui.NotificationsCheck.Add_Click({ Update-RunningSetting 'Notifications' ([bool]$script:ui.NotificationsCheck.IsChecked) })
$script:ui.SoundCheck.Add_Click({ Update-RunningSetting 'Sound' ([bool]$script:ui.SoundCheck.IsChecked) })
$script:ui.SkipExistingCheck.Add_Click({ Update-RunningSetting 'SkipExisting' ([bool]$script:ui.SkipExistingCheck.IsChecked) })
$script:ui.ParallelCombo.IsEnabled = -not [bool]$script:ui.AutoParallelCheck.IsChecked

$script:Window.Add_Closing({
    param($sender, $e)
    if ($script:IsRunning) {
        $answer = Show-ThemedYesNo -message 'Hay un trabajo en curso. ¿Pedir una pausa segura y esperar a que terminen las conversiones activas? La ventana permanecerá abierta hasta que se haya guardado el estado.' -title 'Trabajo en curso' -kind 'Warning' -defaultYes $false
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            $e.Cancel = $true
            $script:CloseWhenPaused = $true
            Stop-RequestedWork
        } else { $e.Cancel = $true }
    } elseif ($script:DuplicateMode) {
        $answer = Show-ThemedYesNo -message 'El análisis de duplicados sigue activo. ¿Cancelar el análisis y cerrar?' -title 'Análisis en curso' -kind 'Warning' -defaultYes $false
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) { $e.Cancel = $true; $script:CloseWhenDuplicateFinishes = $true; Cancel-DuplicateAnalysis }
        else { $e.Cancel = $true }
    } else {
        Save-Preferences
        Set-KeepAwake $false
        if ($script:NotificationIcon) { $script:NotificationIcon.Visible = $false; $script:NotificationIcon.Dispose() }
        if ($script:CpuCounter) { try { $script:CpuCounter.Dispose() } catch {} }
    }
})

try {
    Load-Profiles
    Load-Preferences
    if ([string]::IsNullOrWhiteSpace($script:ui.RootPathBox.Text)) { $script:ui.StartButton.IsEnabled = $false }
    else { $script:ui.StartButton.IsEnabled = Test-Path -LiteralPath $script:ui.RootPathBox.Text -PathType Container; Update-RecoveryState }
    $script:ui.ProgressBar.Value = 0
    [void]$script:Window.ShowDialog()
} catch {
    $startupError = Join-Path $script:AppRoot 'StartupErrors.log'
    Add-Content -LiteralPath $startupError -Value ((Get-Date).ToString('o') + ' ' + $_.Exception.ToString())
    [System.Windows.Forms.MessageBox]::Show("Se ha producido un error. Detalle guardado en:`r`n$startupError`r`n`r`n$($_.Exception.Message)", 'BookForge', 'OK', 'Error') | Out-Null
} finally {
    Set-KeepAwake $false
    if ($script:JournalWriter) { try { $script:JournalWriter.Flush(); $script:JournalWriter.Dispose() } catch {} }
    Dispose-Enumerators
    if ($script:NotificationIcon) { try { $script:NotificationIcon.Visible = $false; $script:NotificationIcon.Dispose() } catch {} }
    if ($script:SingleInstanceMutex) {
        if ($script:SingleInstanceAcquired) { try { $script:SingleInstanceMutex.ReleaseMutex() } catch {} }
        try { $script:SingleInstanceMutex.Dispose() } catch {}
    }
}
