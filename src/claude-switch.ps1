# Switch the Claude desktop account by swapping its Electron web session.
# The Claude desktop app keeps its login in the browser session (cookies +
# Local Storage + IndexedDB), so switching means closing the app, swapping
# those session folders for a saved account's, and restarting.
#
# IMPORTANT: run from a STANDALONE PowerShell window - THIS CLOSES the Claude
# app (and any session running inside it).

$store          = Join-Path $env:USERPROFILE '.claude-accounts'
$RawBase        = 'https://raw.githubusercontent.com/nlimper/claude-account-switcher/main'

# -- Update check (best-effort, cached once per day) ---------------------------
function Test-ForUpdate {
    try {
        $checkFile = Join-Path $env:USERPROFILE '.claude-tools\.update-check'
        if (Test-Path $checkFile) {
            if (((Get-Date) - (Get-Item $checkFile).LastWriteTime) -lt [TimeSpan]::FromDays(1)) { return }
        }
        New-Item -ItemType File -Force -Path $checkFile | Out-Null
        (Get-Date -Format o) | Set-Content -Path $checkFile -ErrorAction SilentlyContinue
        $remote  = (Invoke-RestMethod -Uri "$RawBase/VERSION" -TimeoutSec 4).ToString().Trim()
        $verFile = Join-Path $env:USERPROFILE '.claude-tools\.version'
        $local   = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { '0.0.0' }
        if ([version]$remote -gt [version]$local) {
            Write-Host ""
            Write-Host "  * Update available: v$local -> v$remote   (run 'claude-switch-update')" -ForegroundColor Yellow
        }
    } catch {}
}

# Number of complete live-profile backups to keep. An older backup is only
# removed once a newer one has been verified as a usable profile.
$KeepBackups    = 2

# -- Resolve the live session root (handles MSIX/Store + plain installs) --------
# Claude Desktop has kept its profile in %APPDATA%\Claude (plain install), in
# the MSIX-virtualised Packages\Claude_*\LocalCache\Roaming\Claude, and in newer
# builds in %LOCALAPPDATA%\Claude-Data\<package>. When the app moves its data it
# leaves the old folder behind, empty except for a '.user-data-left.*' marker.
# Such an abandoned folder must never be read from or written to.
function Test-AbandonedRoot($dir) {
    return [bool](Get-ChildItem $dir -Force -Filter '.user-data-left*' -ErrorAction SilentlyContinue |
        Select-Object -First 1)
}

function Get-SessionRootCandidates {
    $roots = @( Join-Path $env:APPDATA 'Claude' )
    $pkgRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    if (Test-Path $pkgRoot) {
        Get-ChildItem $pkgRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
            $roots += (Join-Path $_.FullName 'LocalCache\Roaming\Claude')
        }
    }
    $dataRoot = Join-Path $env:LOCALAPPDATA 'Claude-Data'
    if (Test-Path $dataRoot) {
        Get-ChildItem $dataRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $roots += $_.FullName }
    }
    return @($roots | Where-Object { (Test-Path $_) -and -not (Test-AbandonedRoot $_) } | Select-Object -Unique)
}

# The root whose cookie database is locked is the one the running app uses;
# otherwise the root with the most recently written cookies. $null when no
# candidate holds a session at all - callers must stop rather than guess.
function Get-SessionRoot {
    $live = $null; $newest = $null; $newestTime = [datetime]::MinValue
    foreach ($r in (Get-SessionRootCandidates)) {
        $ck = Join-Path $r 'Network\Cookies'
        if (Test-Path $ck) {
            if (Test-FileLocked $ck) { $live = $r }
            $t = (Get-Item $ck).LastWriteTime
            if ($t -gt $newestTime) { $newestTime = $t; $newest = $r }
        }
    }
    if ($live) { return $live }
    return $newest
}

function Test-FileLocked($path) {
    try { $fs = [IO.File]::Open($path, 'Open', 'Read', 'None'); $fs.Close(); return $false } catch { return $true }
}

# Returns $null when $dir holds a complete, logged-in Claude profile, otherwise
# a short reason. Every copy is checked with this before and after, so an empty
# or abandoned folder can never overwrite a saved account or backup.
function Test-ClaudeProfile($dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return 'folder does not exist' }
    if (Test-AbandonedRoot $dir) { return 'Claude moved its data out of this folder' }
    foreach ($f in 'Local State', 'Network\Cookies') {
        if (-not (Test-Path (Join-Path $dir $f))) { return "'$f' is missing" }
    }
    $raw = Read-FileShared (Join-Path $dir 'config.json')
    if (-not $raw) { return "'config.json' is missing or unreadable" }
    try { $cfg = ConvertFrom-Json $raw -ErrorAction Stop } catch { return "'config.json' is not valid JSON" }
    if (-not ($cfg.'oauth:tokenCacheV2' -or $cfg.'oauth:tokenCache')) { return 'not logged in (token cache is empty)' }
    return $null
}

# Mirror a verified profile into a saved account. The previous snapshot is
# first kept as '<destination>.prev' (incremental mirror, so cheap after the
# first time) and put back if the new copy fails verification. Returns $null
# on success, otherwise the reason it refused or failed.
function Save-ClaudeProfile($source, $destination) {
    $why = Test-ClaudeProfile $source
    if ($why) { return "source $source is not usable: $why" }
    $prev = "$destination.prev"
    if (-not (Test-ClaudeProfile $destination)) {
        if (-not (Copy-ClaudeProfile $destination $prev)) { return "could not keep the previous snapshot in $prev" }
    }
    if ((Copy-ClaudeProfile $source $destination) -and -not (Test-ClaudeProfile $destination)) { return $null }
    if (-not (Test-ClaudeProfile $prev)) { Copy-ClaudeProfile $prev $destination | Out-Null }
    return "the copy in $destination did not verify; the previous snapshot was put back"
}

# The Claude desktop app's own processes. Claude Code sessions it started run
# from the profile's claude-code folder and are left to the app to end.
function Get-ClaudeAppProcesses {
    return @(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -like '*WindowsApps\Claude_*' -or $_.Path -like '*\Claude\Claude.exe' })
}

function Wait-ClaudeExit($seconds) {
    for ($i = 0; $i -lt $seconds * 2; $i++) {
        if (-not (Get-ClaudeAppProcesses)) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

# Disk files of the Cowork VM in this profile that some process still has
# open. While any is open the VM is running on this profile, sharing its
# folders, and nothing in the profile may be touched.
function Get-OpenVmDisks($root) {
    return @(Get-ChildItem (Join-Path $root 'vm_bundles') -Recurse -File -Filter '*.vhdx' -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-FileLocked $_.FullName } | ForEach-Object { $_.Name })
}

# Quit Claude the way a user does, so it stops its Cowork VM and releases the
# profile. Killing it would leave the VM running: the VM belongs to the
# CoworkVMService, not to the app. Returns $null once the app has quit, the
# session files are unlocked and no VM disk is open; otherwise the reason.
function Stop-Claude($root) {
    $procs = Get-ClaudeAppProcesses
    if ($procs) {
        # Closing the window usually only hides the app in the system tray; an
        # app that has no window is already there. Either way, ask the user
        # soon instead of waiting.
        $windows = @($procs | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
        $windows | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $wait = if ($windows) { 5 } else { 1 }
        if (-not (Wait-ClaudeExit $wait)) {
            Write-Host "Claude is still running (closing its window may only hide it in the system tray)." -ForegroundColor Yellow
            Write-Host "Quit it: right-click the Claude icon in the system tray and choose Quit." -ForegroundColor Yellow
            while (-not (Wait-ClaudeExit 5)) {
                $ans = Read-Host "Press Enter once Claude has quit, or type c to cancel"
                if ($ans -match '^c') { return 'Claude is still running' }
            }
        }
    }
    $ck = Join-Path $root 'Network\Cookies'
    $unlocked = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (-not (Test-Path $ck) -or -not (Test-FileLocked $ck)) { $unlocked = $true; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $unlocked) { return 'its session files are still locked' }
    Write-Host "Waiting for the Cowork VM to stop..." -ForegroundColor DarkGray
    for ($i = 0; $i -lt 60; $i++) {
        $open = Get-OpenVmDisks $root
        if (-not $open) { return $null }
        Start-Sleep -Milliseconds 500
    }
    return "the Cowork VM is still running ($($open -join ', ') in use)"
}

# Keep a failure on screen: the Desktop shortcut's window closes as soon as
# the script ends.
function Wait-ForEnter {
    Read-Host "Press Enter to close" | Out-Null
}

function Start-Claude {
    $a = Get-StartApps | Where-Object { $_.Name -match 'claude' } | Select-Object -First 1
    if ($a) { Start-Process "shell:AppsFolder\$($a.AppID)" ; return $true }
    return $false
}

function Copy-ClaudeProfile($source, $destination) {
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    # '.user-data-*' markers describe the folder (Claude's own bookkeeping for
    # moving its data), not the account: never copied, and /XF also keeps
    # robocopy from deleting the ones in the destination.
    $out = robocopy $source $destination /MIR /COPY:DAT /DCOPY:DAT /XJ /XF '.user-data-*' /R:1 /W:1 /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -gt 7) {
        # Keep robocopy's report, so it shows which file stopped the copy.
        try {
            $log = Join-Path $store 'copy-errors.log'
            $head = "=== {0}  robocopy exit {1}`r`n{2} -> {3}" -f (Get-Date -Format 's'), $LASTEXITCODE, $source, $destination
            Add-Content -Path $log -Value (@($head) + @($out | Where-Object { $_ -and $_.Trim() }) + '') -Encoding UTF8
            Write-Host "Copy failed; details in $log" -ForegroundColor Red
        } catch {}
        return $false
    }

    Get-ChildItem $destination -Force -Filter 'Singleton*' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $true
}

# -- Usage display -------------------------------------------------------------
# AES-256-GCM decrypt of the app's tokenCache via bcrypt.dll (Windows' native
# CNG crypto library) through a direct P/Invoke - no external process, no temp
# script files, no Node dependency. PowerShell 5.1's .NET Framework has no
# built-in AesGcm class (that only ships in .NET 5+), so this is the only
# in-process option that works on both 5.1 (the Desktop shortcut's shell) and
# pwsh 7. Deliberately not shelling out to node/cmd here: reading a browser-
# style credential store, decrypting it, and spawning a child process to do so
# is the exact behavioral pattern security software flags as credential
# theft - this keeps everything in-process and inspectable.
$BCryptSrc = @'
using System;
using System.Runtime.InteropServices;

public static class BCryptAesGcm
{
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    static extern uint BCryptOpenAlgorithmProvider(out IntPtr phAlgorithm, string pszAlgId, string pszImplementation, uint dwFlags);
    [DllImport("bcrypt.dll", CharSet = CharSet.Unicode)]
    static extern uint BCryptSetProperty(IntPtr hObject, string pszProperty, string pbInput, int cbInput, uint dwFlags);
    [DllImport("bcrypt.dll")]
    static extern uint BCryptGenerateSymmetricKey(IntPtr hAlgorithm, out IntPtr phKey, IntPtr pbKeyObject, uint cbKeyObject, byte[] pbSecret, uint cbSecret, uint dwFlags);
    [DllImport("bcrypt.dll")]
    static extern uint BCryptDestroyKey(IntPtr hKey);
    [DllImport("bcrypt.dll")]
    static extern uint BCryptCloseAlgorithmProvider(IntPtr hAlgorithm, uint dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    struct BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO
    {
        public uint cbSize; public uint dwInfoVersion;
        public IntPtr pbNonce; public uint cbNonce;
        public IntPtr pbAuthData; public uint cbAuthData;
        public IntPtr pbTag; public uint cbTag;
        public IntPtr pbMacContext; public uint cbMacContext;
        public uint cbAAD; public ulong cbData; public uint dwFlags;
    }

    [DllImport("bcrypt.dll")]
    static extern uint BCryptDecrypt(IntPtr hKey, byte[] pbInput, uint cbInput, ref BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO pPaddingInfo, byte[] pbIV, uint cbIV, byte[] pbOutput, uint cbOutput, out uint pcbResult, uint dwFlags);

    public static byte[] Decrypt(byte[] key, byte[] nonce, byte[] cipherText, byte[] tag)
    {
        IntPtr hAlg = IntPtr.Zero, hKey = IntPtr.Zero;
        uint status = BCryptOpenAlgorithmProvider(out hAlg, "AES", null, 0);
        if (status != 0) throw new Exception("OpenAlgorithmProvider failed: 0x" + status.ToString("X"));
        string mode = "ChainingModeGCM";
        status = BCryptSetProperty(hAlg, "ChainingMode", mode, (mode.Length + 1) * 2, 0);
        if (status != 0) throw new Exception("SetProperty failed: 0x" + status.ToString("X"));
        status = BCryptGenerateSymmetricKey(hAlg, out hKey, IntPtr.Zero, 0, key, (uint)key.Length, 0);
        if (status != 0) throw new Exception("GenerateSymmetricKey failed: 0x" + status.ToString("X"));
        GCHandle nonceHandle = GCHandle.Alloc(nonce, GCHandleType.Pinned);
        GCHandle tagHandle = GCHandle.Alloc(tag, GCHandleType.Pinned);
        try
        {
            var info = new BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO();
            info.cbSize = (uint)Marshal.SizeOf(typeof(BCRYPT_AUTHENTICATED_CIPHER_MODE_INFO));
            info.dwInfoVersion = 1;
            info.pbNonce = nonceHandle.AddrOfPinnedObject(); info.cbNonce = (uint)nonce.Length;
            info.pbTag = tagHandle.AddrOfPinnedObject(); info.cbTag = (uint)tag.Length;
            byte[] output = new byte[cipherText.Length];
            uint resultLen;
            status = BCryptDecrypt(hKey, cipherText, (uint)cipherText.Length, ref info, null, 0, output, (uint)output.Length, out resultLen, 0);
            if (status != 0) throw new Exception("BCryptDecrypt failed: 0x" + status.ToString("X"));
            byte[] result = new byte[resultLen];
            Array.Copy(output, result, resultLen);
            return result;
        }
        finally
        {
            nonceHandle.Free(); tagHandle.Free();
            if (hKey != IntPtr.Zero) BCryptDestroyKey(hKey);
            if (hAlg != IntPtr.Zero) BCryptCloseAlgorithmProvider(hAlg, 0);
        }
    }
}
'@
try { [BCryptAesGcm] | Out-Null } catch { Add-Type -TypeDefinition $BCryptSrc -Language CSharp -ErrorAction SilentlyContinue }
Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Read-FileShared($path) {
    try {
        $fs     = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $reader = New-Object System.IO.StreamReader($fs)
        $text   = $reader.ReadToEnd()
        $reader.Close(); $fs.Close()
        return $text
    } catch { return $null }
}

function Get-TokenCacheBlob($root) {
    try {
        $raw = Read-FileShared (Join-Path $root 'config.json')
        if (-not $raw) { return $null }
        $cfg = ConvertFrom-Json $raw -ErrorAction Stop
        # Claude Desktop's V1 entry can be an empty placeholder. Prefer V2 but
        # retain V1 compatibility for older desktop builds.
        $blob = $cfg.'oauth:tokenCacheV2'
        if (-not $blob) { $blob = $cfg.'oauth:tokenCache' }
        return $blob
    } catch { return $null }
}

function Get-AesKey($root) {
    try {
        $ls = Read-FileShared (Join-Path $root 'Local State')
        if (-not $ls) { return $null }
        $b64   = ($ls | ConvertFrom-Json).os_crypt.encrypted_key
        $bytes = [Convert]::FromBase64String($b64)
        return [System.Security.Cryptography.ProtectedData]::Unprotect(
                   $bytes[5..($bytes.Length - 1)], $null,
                   [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch { return $null }
}

function Get-TokenFromBlob($blob, $key) {
    if (-not $blob -or -not $key) { return $null }
    try {
        $bytes        = [Convert]::FromBase64String($blob)
        $nonce        = $bytes[3..14]
        $cipherAndTag = $bytes[15..($bytes.Length - 1)]
        $cipherLen    = $cipherAndTag.Length - 16
        $cipherText   = $cipherAndTag[0..($cipherLen - 1)]
        $tag          = $cipherAndTag[$cipherLen..($cipherAndTag.Length - 1)]
        $plainBytes   = [BCryptAesGcm]::Decrypt($key, $nonce, $cipherText, $tag)
        $plainText    = [System.Text.Encoding]::UTF8.GetString($plainBytes)
        $entry        = ($plainText | ConvertFrom-Json).PSObject.Properties.Value | Select-Object -First 1
        return $entry.token
    } catch { return $null }
}

# HttpClient, not Invoke-RestMethod: under Windows PowerShell 5.1 (the Desktop
# shortcut's shell) Invoke-RestMethod hangs indefinitely reading a SUCCESSFUL
# response from this endpoint (-TimeoutSec doesn't cover the read stall);
# error responses return instantly. HttpClient with its own Timeout is immune.
$HttpClient = $null
function Get-ClaudeUsage($accessToken) {
    if (-not $accessToken) { return $null }
    try {
        if (-not $script:HttpClient) {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $script:HttpClient = New-Object System.Net.Http.HttpClient($handler)
            $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(6)
        }
        $req = New-Object System.Net.Http.HttpRequestMessage('GET', 'https://api.anthropic.com/api/oauth/usage')
        $req.Headers.Add('Authorization', "Bearer $accessToken")
        $req.Headers.Add('anthropic-version', '2023-06-01')
        $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
        $resp = $script:HttpClient.SendAsync($req).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { return $null }
        $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return ($body | ConvertFrom-Json)
    } catch { return $null }
}

function Get-UsageFromBlob($blob, $key) {
    $tok = Get-TokenFromBlob $blob $key
    if (-not $tok) { return $null }
    return Get-ClaudeUsage $tok
}

# Email of the account the live profile is ACTUALLY logged into, asked from the
# OAuth profile endpoint (same check claude-add uses). Returns the email,
# 'EMPTY' when the token cache holds no token (logged out), or $null when it
# could not be determined (expired token, network, decrypt failure).
function Get-LoggedInEmail($root) {
    $blob = Get-TokenCacheBlob $root
    if (-not $blob) { return 'EMPTY' }
    $tok = Get-TokenFromBlob $blob (Get-AesKey $root)
    if (-not $tok) { return $null }
    try {
        if (-not $script:HttpClient) {
            $handler = New-Object System.Net.Http.HttpClientHandler
            $script:HttpClient = New-Object System.Net.Http.HttpClient($handler)
            $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(6)
        }
        $req = New-Object System.Net.Http.HttpRequestMessage('GET', 'https://api.anthropic.com/api/oauth/profile')
        $req.Headers.Add('Authorization', "Bearer $tok")
        $req.Headers.Add('anthropic-version', '2023-06-01')
        $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
        $resp = $script:HttpClient.SendAsync($req).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { return $null }
        $j = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
        if ($j.account.email) { return $j.account.email }
    } catch {}
    return $null
}

# After a relaunch, the profile folder the app actually runs from: the one
# whose cookie database it locks. Claude may move its data to another folder
# while it starts, so all candidates are checked, not only the one that was
# written. $null when the app locks none of them within 30 seconds.
function Find-RunningProfile {
    for ($i = 0; $i -lt 60; $i++) {
        foreach ($r in (Get-SessionRootCandidates)) {
            $ck = Join-Path $r 'Network\Cookies'
            if ((Test-Path $ck) -and (Test-FileLocked $ck)) { return $r }
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# Format the reset times into a short, human line (local time). The 5h limit is
# close so it's shown as a countdown; the weekly limit is shown as a date+time.
function Format-Resets($u) {
    if (-not $u) { return $null }
    $now   = Get-Date
    $parts = @()
    try {
        $r5 = [datetimeoffset]::Parse($u.five_hour.resets_at).LocalDateTime
        $d  = $r5 - $now
        if ($d.TotalSeconds -gt 0) {
            $rel = if ($d.TotalHours -ge 1) { "{0}h{1:00}m" -f [int]$d.TotalHours, $d.Minutes } else { "{0}m" -f [int]$d.TotalMinutes }
            $parts += "5h resets in $rel ($($r5.ToString('HH:mm')))"
        }
    } catch {}
    try {
        $r7 = [datetimeoffset]::Parse($u.seven_day.resets_at).LocalDateTime
        $parts += "7d resets $($r7.ToString('ddd MMM d, HH:mm'))"
    } catch {}
    if ($parts.Count) { return ($parts -join '   |   ') }
    return $null
}

# -- Load saved accounts -------------------------------------------------------
$accounts = Get-ChildItem $store -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'meta.json') }
if (-not $accounts) {
    Write-Host "No saved Claude accounts." -ForegroundColor Yellow
    Write-Host "Log into Claude, then run 'claude-add-account' to save each account." -ForegroundColor Yellow
    Start-Sleep -Seconds 3; return
}

$list = @()
$legacyCount = 0
foreach ($a in $accounts) {
    try { $m = Get-Content (Join-Path $a.FullName 'meta.json') -Raw | ConvertFrom-Json } catch { continue }
    $profile = Join-Path $a.FullName 'profile'
    if (-not (Test-Path $profile)) { $legacyCount++; continue }
    $list += [pscustomobject]@{ Email = $m.email; Dir = $a.FullName; Profile = $profile
                                Token = (Get-TokenCacheBlob $profile); Problem = (Test-ClaudeProfile $profile) }
}
if (-not $list) {
    if ($legacyCount) {
        Write-Host "Your saved desktop accounts use the retired partial-session format." -ForegroundColor Yellow
        Write-Host "Sign in to each account once, then run claude-add-account to create complete-profile snapshots." -ForegroundColor Yellow
    } else {
        Write-Host "No usable Claude accounts were found. Run claude-add-account after signing in." -ForegroundColor Yellow
    }
    Start-Sleep -Seconds 4; return
}

# -- Display picker ------------------------------------------------------------
Write-Host ""
Write-Host "=== Switch Claude account ===" -ForegroundColor Cyan
Test-ForUpdate

$root = Get-SessionRoot
if (-not $root) {
    Write-Host "Claude app data not found (no profile with a session in %APPDATA%\Claude," -ForegroundColor Red
    Write-Host "%LOCALAPPDATA%\Packages\Claude_* or %LOCALAPPDATA%\Claude-Data). Open Claude once, then retry." -ForegroundColor Red
    Wait-ForEnter; return
}

# Identify the account the live session belongs to. Ask the server first: the
# app rotates its tokens while it runs, so both a token match and the marker
# written on the last switch can be stale, and syncing the live session into
# the wrong saved account destroys that account's snapshot.
$currentFile = Join-Path $store '.current'
$liveProblem = Test-ClaudeProfile $root
$liveEmail   = $null
$currentAcct = $null
$currentSure = $false
if (-not $liveProblem) {
    $liveEmail = Get-LoggedInEmail $root
    if ($liveEmail -and $liveEmail -ne 'EMPTY') {
        $currentAcct = $list | Where-Object { $_.Email -eq $liveEmail } | Select-Object -First 1
        $currentSure = $true
    } else {
        $liveEmail = $null
        $liveToken = Get-TokenCacheBlob $root
        if ($liveToken) { $currentAcct = $list | Where-Object { $_.Token -eq $liveToken } | Select-Object -First 1 }
        if (-not $currentAcct -and (Test-Path $currentFile)) {
            try {
                $curEmail    = (Get-Content $currentFile -Raw).Trim()
                $currentAcct = $list | Where-Object { $_.Email -eq $curEmail } | Select-Object -First 1
            } catch {}
        }
    }
}
Write-Host "Fetching usage..." -ForegroundColor DarkGray

for ($i = 0; $i -lt $list.Count; $i++) {
    $mark = if ($currentAcct -and $list[$i].Email -eq $currentAcct.Email) { '*' } else { ' ' }
    if ($list[$i].Problem) {
        Write-Host ("  [{0}] {1} {2,-32}  snapshot unusable: {3}" -f ($i + 1), $mark, $list[$i].Email, $list[$i].Problem) -ForegroundColor Red
        continue
    }
    # Each saved profile has its own Local State key; the live one cannot
    # decrypt the token cache of an account saved from a cleared profile.
    $u = Get-UsageFromBlob $list[$i].Token (Get-AesKey $list[$i].Profile)
    $usageStr = if ($u) { "  5h {0,3}% / 7d {1,3}% used" -f [int]$u.five_hour.utilization, [int]$u.seven_day.utilization } else { "  usage n/a" }
    Write-Host ("  [{0}] {1} {2,-32}{3}" -f ($i + 1), $mark, $list[$i].Email, $usageStr)
    $resetStr = Format-Resets $u
    if ($resetStr) { Write-Host ("        $resetStr") -ForegroundColor DarkGray }
}
Write-Host "  (* = current   |   lower % = more headroom)" -ForegroundColor DarkGray
Write-Host "  Live profile: $root" -ForegroundColor DarkGray
if ($liveProblem) {
    Write-Host "  The live profile is $liveProblem - it will be backed up, not saved to an account." -ForegroundColor Yellow
} elseif (-not $currentAcct) {
    $who = if ($liveEmail) { $liveEmail } else { 'an unidentified account' }
    Write-Host "  The live session ($who) is not a saved account - it will only be kept in the backup." -ForegroundColor Yellow
    Write-Host "  Run 'claude-add-account' first to keep it switchable." -ForegroundColor Yellow
} elseif (-not $currentSure) {
    Write-Host "  Could not verify the live account online; assuming $($currentAcct.Email)." -ForegroundColor Yellow
}
Write-Host ""
$pick = Read-Host "Pick an account number (or Enter to cancel)"
if ([string]::IsNullOrWhiteSpace($pick)) { Write-Host "Cancelled." -ForegroundColor Yellow; return }
if ($pick -notmatch '^\d+$' -or [int]$pick -lt 1 -or [int]$pick -gt $list.Count) {
    Write-Host "Invalid choice." -ForegroundColor Red; Start-Sleep -Seconds 2; return
}
$chosen      = $list[[int]$pick - 1]
if ($chosen.Problem) {
    Write-Host "The saved snapshot for $($chosen.Email) is unusable ($($chosen.Problem))." -ForegroundColor Red
    Write-Host "Sign in to that account and run 'claude-add-account' to save it again." -ForegroundColor Red
    Wait-ForEnter; return
}
if ($currentAcct -and -not $currentSure) {
    $ans = Read-Host "Save the live session back into $($currentAcct.Email)? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { $currentAcct = $null }
}
if (-not $liveProblem -and -not $currentAcct) {
    $ans = Read-Host "The live session will only be kept in the backup. Continue? [y/N]"
    if ($ans -notmatch '^(y|yes)$') { Write-Host "Cancelled." -ForegroundColor Yellow; return }
}

# -- Perform the swap ----------------------------------------------------------
Write-Host ""
Write-Host "Closing Claude..." -ForegroundColor Cyan
$why = Stop-Claude $root
if ($why) {
    Write-Host "Could not close Claude cleanly: $why. Nothing was changed." -ForegroundColor Red
    Wait-ForEnter; return
}

# Any unexpected error from here on aborts the switch instead of carrying on
# with a half-done swap.
$ErrorActionPreference = 'Stop'
$backup = Join-Path $store ('.backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
try {
    # Back up the complete live profile so a bad swap is recoverable.
    Write-Host "Backing up current profile..." -ForegroundColor DarkGray
    if (-not (Copy-ClaudeProfile $root (Join-Path $backup 'profile'))) {
        throw "could not back up the live profile to $backup"
    }

    # Prune old backups (complete profiles are large), counting only verified
    # ones, so a broken live profile can never push the last good backup out.
    Get-ChildItem $store -Directory -Filter '.backup-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Where-Object { -not (Test-ClaudeProfile (Join-Path $_.FullName 'profile')) } |
        Select-Object -Skip $KeepBackups |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Sync the entire live profile back before loading another account. This keeps
    # every authentication component consistent as Claude changes its storage.
    if ($currentAcct) {
        Write-Host "Refreshing saved profile for $($currentAcct.Email)..." -ForegroundColor DarkGray
        $err = Save-ClaudeProfile $root $currentAcct.Profile
        if ($err) { throw "could not refresh the saved profile for $($currentAcct.Email): $err" }
    }

    Write-Host "Loading complete profile for $($chosen.Email)..." -ForegroundColor Cyan
    if (-not (Copy-ClaudeProfile $chosen.Profile $root) -or (Test-ClaudeProfile $root)) {
        Copy-ClaudeProfile (Join-Path $backup 'profile') $root | Out-Null
        throw "could not load the profile of $($chosen.Email); the previous live profile was put back from $backup"
    }

    # Remember which saved account the live session now belongs to, as a
    # fallback for the next switch when the account cannot be verified online.
    try {
        [System.IO.File]::WriteAllText($currentFile, $chosen.Email, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
} catch {
    Write-Host "Switch aborted: $($_.Exception.Message)" -ForegroundColor Red
    Start-Claude | Out-Null
    Wait-ForEnter; return
} finally {
    $ErrorActionPreference = 'Continue'
}

Write-Host "Reopening Claude..." -ForegroundColor Cyan
if (-not (Start-Claude)) {
    Write-Host "Session swapped, but the Claude app wasn't found to relaunch - open it manually." -ForegroundColor Yellow
    Wait-ForEnter; return
}
# Check which account the running app actually has, wherever it keeps its data.
$running = Find-RunningProfile
Write-Host ""
if (-not $running) {
    Write-Host "Claude did not open a profile within 30 seconds; check which account it shows." -ForegroundColor Red
    Write-Host "The previous live profile is in $backup." -ForegroundColor Red
    Wait-ForEnter; return
}
if ($running -ne $root) {
    Write-Host "Claude moved its data to $running while starting." -ForegroundColor DarkGray
}
$runningEmail = Get-LoggedInEmail $running
if ($runningEmail -eq $chosen.Email) {
    Write-Host "Done - Claude is running as $($chosen.Email)." -ForegroundColor Green
    Start-Sleep -Seconds 2
} elseif ($runningEmail -and $runningEmail -ne 'EMPTY') {
    Write-Host "Claude is running as $runningEmail, not as $($chosen.Email)." -ForegroundColor Red
    Write-Host "The previous live profile is in $backup." -ForegroundColor Red
    Wait-ForEnter
} else {
    Write-Host "Claude is running, but its account could not be verified online." -ForegroundColor Yellow
    Write-Host "Check that it shows $($chosen.Email)." -ForegroundColor Yellow
    Wait-ForEnter
}
