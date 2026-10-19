<#
    Claude Account Switcher - uninstaller

    One-line uninstall:
      irm https://raw.githubusercontent.com/nlimper/claude-account-switcher/main/uninstall.ps1 | iex

    Removes the scripts, the Desktop shortcuts, and the added commands from your
    PowerShell profiles. Does NOT touch your saved accounts (~/.claude-accounts)
    or your Claude login. Remove saved accounts manually if you want:
      Remove-Item -Recurse -Force ~/.claude-accounts
#>

Write-Host "Removing Claude Account Switcher..." -ForegroundColor Cyan

$ToolsDir = Join-Path $env:USERPROFILE '.claude-tools'

# 1. Desktop shortcuts: every shortcut that runs a script from the tools dir
#    (also those created by older versions).
$desktop = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
Get-ChildItem $desktop -Filter '*.lnk' -ErrorAction SilentlyContinue | ForEach-Object {
    $lnkArgs = $ws.CreateShortcut($_.FullName).Arguments
    if ($lnkArgs -and $lnkArgs.Contains($ToolsDir)) {
        Remove-Item -Force $_.FullName
        Write-Host " - removed Desktop shortcut '$($_.Name)'"
    }
}

# 2. Tools dir
if (Test-Path $ToolsDir) { Remove-Item -Recurse -Force $ToolsDir; Write-Host " - removed $ToolsDir" }

# 3. Commands from both PowerShell profiles: the marker-delimited block the
#    installer writes, and the un-delimited block of older versions.
$beginMark = '# >>> claude-account-switcher >>>'
$endMark   = '# <<< claude-account-switcher <<<'
$docs = [Environment]::GetFolderPath('MyDocuments')
$profiles = @(
    (Join-Path $docs 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $docs 'PowerShell\Microsoft.PowerShell_profile.ps1')
)
foreach ($pf in $profiles) {
    if (-not (Test-Path $pf)) { continue }
    $c = Get-Content $pf -Raw -ErrorAction SilentlyContinue
    if ($null -eq $c) { continue }
    $pattern = [Regex]::Escape($beginMark) + '.*?' + [Regex]::Escape($endMark)
    $new = [Regex]::Replace($c, $pattern, '', 'Singleline')
    $new = $new -replace '(?s)\r?\n#\s*Claude desktop account switcher[^\r\n]*.*?function\s+claude-add-account\s*\{[^}]*\}', ''
    if ($new -ne $c) {
        Set-Content -Path $pf -Value ($new.TrimEnd() + "`r`n") -Encoding UTF8
        Write-Host " - cleaned $pf"
    }
}

Write-Host "Done. Open a new PowerShell window for changes to take effect." -ForegroundColor Green
