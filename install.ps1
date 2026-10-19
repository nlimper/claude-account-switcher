<#
    Claude Account Switcher - installer (Windows only)

    One-line install (PowerShell):
      irm https://raw.githubusercontent.com/nlimper/claude-account-switcher/main/install.ps1 | iex

    Installs:
      - ~/.claude-tools/claude-switch.ps1 and claude-add.ps1
      - claude-switch-account / claude-add-account / claude-switch-update
        commands in your PowerShell profiles (5.1 and 7)
      - a "Claude Switch Account" shortcut on the Desktop
#>

$RawBase     = 'https://raw.githubusercontent.com/nlimper/claude-account-switcher/main'
$ToolsDir    = Join-Path $HOME '.claude-tools'
$SwitchPath  = Join-Path $ToolsDir 'claude-switch.ps1'
$AddPath     = Join-Path $ToolsDir 'claude-add.ps1'
$VersionPath = Join-Path $ToolsDir '.version'

Write-Host ""
Write-Host "=== Claude Account Switcher - installer ===" -ForegroundColor Cyan

# $IsWindows only exists on PowerShell 7+; Windows PowerShell 5.1 is Windows.
if ((Test-Path variable:IsWindows) -and -not $IsWindows) {
    Write-Host "The Claude desktop app switcher only works on Windows." -ForegroundColor Red
    return
}

# 1. Fetch the scripts.
Write-Host "[1/3] Installing scripts to $ToolsDir ..." -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $ToolsDir | Out-Null
try {
    Invoke-RestMethod -Uri "$RawBase/src/claude-switch.ps1" -OutFile $SwitchPath
    Invoke-RestMethod -Uri "$RawBase/src/claude-add.ps1"    -OutFile $AddPath
} catch {
    Write-Host "ERROR: could not download scripts from GitHub." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}

# Record the installed version (used by the daily update check).
try {
    $ver = (Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 8).ToString().Trim()
    Set-Content -Path $VersionPath -Value $ver -Encoding ASCII
    Write-Host "      Installed version $ver" -ForegroundColor DarkGray
} catch {}

# 2. Add commands to PowerShell profiles (5.1 + 7)
Write-Host "[2/3] Adding the switch commands to your PowerShell profiles..." -ForegroundColor Cyan
$docs = [Environment]::GetFolderPath('MyDocuments')   # honours OneDrive redirection
$profiles = @(
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
)
# Marker-delimited block so re-running the installer cleanly REPLACES the old
# definitions (lets us add/rename commands on update without leaving dupes).
$beginMark = '# >>> claude-account-switcher >>>'
$endMark   = '# <<< claude-account-switcher <<<'
$func = @"
$beginMark
# Claude desktop app account switcher (managed by claude-account-switcher installer)
function claude-switch-account { & "$SwitchPath" }
function claude-add-account    { & "$AddPath" }
function claude-switch-update {
    Write-Host "Updating Claude Account Switcher..." -ForegroundColor Cyan
    irm $RawBase/install.ps1 | iex
    Write-Host "Done. Open a new PowerShell window to load the updated commands." -ForegroundColor Green
}
$endMark
"@
foreach ($pf in $profiles) {
    $dir = Split-Path $pf
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not (Test-Path $pf))  { New-Item -ItemType File -Force -Path $pf | Out-Null }
    $c = Get-Content $pf -Raw -ErrorAction SilentlyContinue
    if ($null -eq $c) { $c = '' }
    # Remove any previous managed block (and legacy un-marked block), then append fresh.
    $pattern = [Regex]::Escape($beginMark) + '.*?' + [Regex]::Escape($endMark)
    $c = [Regex]::Replace($c, $pattern, '', 'Singleline')
    # Legacy cleanup: drop any old un-delimited block from earlier versions.
    $c = $c -replace '(?s)\r?\n#\s*Claude desktop account switcher[^\r\n]*.*?function\s+claude-add-account\s*\{[^}]*\}', ''
    $c = $c.TrimEnd() + "`r`n`r`n" + $func + "`r`n"
    Set-Content -Path $pf -Value $c -Encoding UTF8
}

# 3. Desktop shortcut
Write-Host "[3/3] Creating Desktop shortcut..." -ForegroundColor Cyan
$desktop = [Environment]::GetFolderPath('Desktop')
$psExe   = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

$icon = $null
$pkg  = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq 'Claude_pzs8sxrjxfjjc' } | Select-Object -First 1
if ($pkg) {
    $cand = Join-Path $pkg.InstallLocation 'app\Claude.exe'
    if (Test-Path $cand) { $icon = "$cand,0" }
}

$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut((Join-Path $desktop 'Claude Switch Account.lnk'))
$sc.TargetPath       = $psExe
$sc.Arguments        = "-ExecutionPolicy Bypass -NoProfile -File `"$SwitchPath`""
$sc.WorkingDirectory = $HOME
if ($icon) { $sc.IconLocation = $icon }
$sc.Description      = 'Switch the Claude desktop app account'
$sc.WindowStyle      = 1
$sc.Save()

Write-Host ""
Write-Host "Done! Claude Account Switcher is installed." -ForegroundColor Green
Write-Host ""
Write-Host "Open a NEW PowerShell window so the commands load:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  claude-add-account      save each account (don't use the app's Log out)" -ForegroundColor Gray
Write-Host "  claude-switch-account   switch (also on the Desktop shortcut)" -ForegroundColor Gray
Write-Host "  claude-switch-update    update to the latest version" -ForegroundColor Gray
