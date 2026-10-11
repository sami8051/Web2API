<#
.SYNOPSIS
  One-command installer/updater for web-to-api (upstream PruhaNLP/web-to-api) + our Windows tray launcher.

.DESCRIPTION
  The same command installs and updates:
    irm https://raw.githubusercontent.com/sami8051/Web2API/main/install.ps1 | iex

  Layout (all under -InstallDir, default %LOCALAPPDATA%\Web2API; safe to delete, holds no user data):
    app\        upstream build (replaced on update; previous build kept in app.prev for -Rollback)
    app.new\    staging area while building; discarded if the build or smoke test fails
    launcher\   web-to-api-tray.ps1 (our tray launcher; a locally edited copy is backed up, never silently lost)
    install.json  what is installed (upstream commit, port, paths) - reused on every update
    logs\       installer logs
  User data lives OUTSIDE that folder and is never touched by install/update/rollback:
    ~\.web-to-api                   sessions, auth flags, settings, logs
    ~\web-to-api\chrome-profile     Chrome profile with your logins

  Switches:
    -Uninstall            stop the tray, remove the startup entry and -InstallDir (user data is kept)
    -Uninstall -RemoveData  ... and also delete state dir + Chrome profile (asks you to type DELETE unless -Yes)
    -Rollback             swap back to the previous upstream build
    -Yes                  answer yes to prompts (Node.js install, startup entry)
    -NoStartup            do not create/refresh the Windows sign-in startup entry
    -Force                rebuild even if upstream is unchanged
  Options (remembered for later updates): -Port 3456  -StateDir  -ChromeProfile  -InstallDir
    -UpstreamRepo PruhaNLP/web-to-api  -UpstreamRef main|tag|sha   -LauncherRef main
  With `irm | iex` you cannot pass switches; use:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/sami8051/Web2API/main/install.ps1))) -Yes
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$RemoveData,
    [switch]$Rollback,
    [switch]$Yes,
    [switch]$NoStartup,
    [switch]$Force,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Web2API'),
    [string]$UpstreamRepo = 'PruhaNLP/web-to-api',
    [string]$UpstreamRef = 'main',
    [string]$LauncherRepo = 'sami8051/Web2API',
    [string]$LauncherRef = 'main',
    [int]$Port = 3456,
    [string]$StateDir = '',
    [string]$ChromeProfile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is ~10x faster without the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$UserHome = $env:USERPROFILE
$ConfigPath = Join-Path $InstallDir 'install.json'
$AppDir = Join-Path $InstallDir 'app'
$AppNew = Join-Path $InstallDir 'app.new'
$AppPrev = Join-Path $InstallDir 'app.prev'
$LauncherDir = Join-Path $InstallDir 'launcher'
$Launcher = Join-Path $LauncherDir 'web-to-api-tray.ps1'
$LogDir = Join-Path $InstallDir 'logs'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'web-to-api.lnk'
$script:Log = $null
$script:Temp = $null

function Say([string]$m) { Write-Host "  $m" }
function Step([string]$m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Ok([string]$m) { Write-Host "  + $m" -ForegroundColor Green }

function Confirm-Yes([string]$question) {
    if ($Yes) { return $true }
    try { $a = Read-Host "$question [Y/n]" } catch { throw "Cannot prompt in a non-interactive session. Re-run with -Yes to accept: $question" }
    return $a -notmatch '^(n|no)$'
}

function Remove-Tree([string]$path) {
    if (Test-Path -LiteralPath $path) { & cmd.exe /c rmdir /s /q "$path" 2>&1 | Out-Null }
    if (Test-Path -LiteralPath $path) { throw "Could not remove $path (is something still using it?)" }
}

# Refuse to ever recursively delete anything that is not clearly a sub-folder of the user's profile.
function Assert-SafeToDelete([string]$path) {
    $full = [IO.Path]::GetFullPath($path).TrimEnd('\')
    $homeFull = [IO.Path]::GetFullPath($UserHome).TrimEnd('\')
    if (-not $full.StartsWith($homeFull + '\', [StringComparison]::OrdinalIgnoreCase) -or $full.Length -le $homeFull.Length + 3) {
        throw "Refusing to delete '$full' (not a sub-folder of $homeFull)"
    }
}

function Save-Config($o) { New-Item -ItemType Directory -Force $InstallDir | Out-Null; $o | ConvertTo-Json | Set-Content $ConfigPath -Encoding UTF8 }

# ---- settings: explicit parameter > remembered in install.json > default ----
$cfg = $null
$Bound = $PSBoundParameters
if (Test-Path $ConfigPath) { try { $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json } catch { Warn "Ignoring unreadable $ConfigPath" } }
# Plain statements (not a helper using Set-Variable -Scope Script): that scope does not exist when this runs as a script block.
# The ref is deliberately NOT remembered: plain re-runs follow main, pin with -UpstreamRef each time.
if ($cfg) {
    if (-not $Bound.ContainsKey('Port') -and $cfg.port) { $Port = $cfg.port }
    if (-not $Bound.ContainsKey('StateDir') -and $cfg.stateDir) { $StateDir = $cfg.stateDir }
    if (-not $Bound.ContainsKey('ChromeProfile') -and $cfg.chromeProfile) { $ChromeProfile = $cfg.chromeProfile }
    if (-not $Bound.ContainsKey('UpstreamRepo') -and $cfg.upstreamRepo) { $UpstreamRepo = $cfg.upstreamRepo }
}
$Port = [int]$Port
# These are the upstream defaults (src/config/paths.ts); only used for -RemoveData and port/launcher args.
$EffStateDir = if ($StateDir) { $StateDir } else { Join-Path $UserHome '.web-to-api' }
$EffProfile = if ($ChromeProfile) { $ChromeProfile } else { Join-Path $UserHome 'web-to-api\chrome-profile' }

# ---- launcher helpers ----
function Get-TrayArgs([string]$extra) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Launcher`"", '-Port', "$Port", '-StateDir', "`"$EffStateDir`"", '-AppDir', "`"$AppDir`"")
    if ($ChromeProfile) { $a += @('-ChromeProfile', "`"$ChromeProfile`"") }
    if ($extra) { $a += $extra.Split(' ') }
    $a
}
function Invoke-Tray([string]$extra) {   # run the tray script's non-GUI modes (-Stop/-Install/-Uninstall) in a child process
    if (-not (Test-Path $Launcher)) { return }
    # WaitForExit, not Start-Process -Wait: -Wait would also wait for the tray that -Install spawns
    $p = Start-Process powershell.exe -ArgumentList (Get-TrayArgs $extra) -PassThru -NoNewWindow
    $null = $p.Handle   # keep the handle so ExitCode is readable
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { throw "Launcher '$extra' failed (exit $($p.ExitCode))" }
}
function Start-Tray { Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (Get-TrayArgs '') | Out-Null }

function Get-PortOwner {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { $n = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName; "$n (PID $($c.OwningProcess))" }
}

function Wait-Health([int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest "http://127.0.0.1:$Port/admin/health" -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { return ($r.Content | ConvertFrom-Json) }
        } catch {
            $resp = $_.Exception.Response
            if ($resp -and [int]$resp.StatusCode -eq 401) { return [pscustomobject]@{ status = 'up (auth token required; health body not readable)' } }
        }
        Start-Sleep -Seconds 2
    }
    $null
}

function Write-Summary([string]$title = 'Done') {
    Step $title
    Ok "Dashboard: http://127.0.0.1:$Port/"
    Ok "API base : http://127.0.0.1:$Port/v1"
    Say "Tray icon: dot near the clock (may be under the ^ arrow). Menu: Start, Stop, Restart, Open Dashboard, Open Logs, Start with Windows, Exit."
    Say "Update   : run the same install command again.   Rollback: add -Rollback.   Uninstall: add -Uninstall."
}

# ================= modes =================
function Invoke-Uninstall {
    Step 'Uninstalling launcher'
    if (Test-Path $Launcher) { Invoke-Tray '-Uninstall' }   # closes tray (stops API), removes startup entry
    elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    if (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
    Ok 'Tray stopped and startup entry removed'
    if (Test-Path $InstallDir) {
        if (-not ((Test-Path $ConfigPath) -or (Test-Path $AppDir) -or (Test-Path $LauncherDir))) { throw "$InstallDir does not look like a Web2API install; not deleting it" }
        Assert-SafeToDelete $InstallDir
        Remove-Tree $InstallDir
        Ok "Removed $InstallDir"
    }
    if ($RemoveData) {
        Step 'Removing user data (explicitly requested)'
        $targets = @($EffStateDir, $EffProfile) | Where-Object { Test-Path $_ }
        foreach ($t in $targets) { Assert-SafeToDelete $t }
        if ($targets.Count -eq 0) { Say 'No user data found.' }
        else {
            $targets | ForEach-Object { Warn "will delete: $_" }
            if (-not $Yes) { if ((Read-Host 'This deletes sessions, logins and settings for good. Type DELETE to continue') -cne 'DELETE') { throw 'Data removal cancelled; launcher already uninstalled, data kept.' } }
            foreach ($t in $targets) { Remove-Tree $t; Ok "Removed $t" }
        }
    } else {
        Say "User data kept: $EffStateDir  and  $EffProfile  (add -RemoveData to delete them)."
    }
}

function Invoke-Rollback {
    Step 'Rolling back to previous upstream build'
    if (-not (Test-Path $AppPrev)) { throw 'No previous build (app.prev) to roll back to.' }
    Invoke-Tray '-Stop'
    $tmp = Join-Path $InstallDir 'app.swap'
    Remove-Tree $tmp
    Rename-Item $AppDir 'app.swap'; Rename-Item $AppPrev 'app'; Rename-Item $tmp 'app.prev'
    if ($cfg) {
        $cur = $cfg.upstreamSha; $cfg.upstreamSha = $cfg.previousSha; $cfg.previousSha = $cur
        Save-Config $cfg
    }
    Ok "Rolled back to upstream $($cfg.upstreamSha)"
    Warn 'The next install/update fetches the latest upstream again; keep this version with -UpstreamRef <sha>.'
    $foreign = Get-PortOwner
    Start-Tray
    Complete-Start $foreign
}

# ================= install / update =================
function Ensure-Node {
    function Get-Major { $n = Get-Command node.exe -ErrorAction SilentlyContinue; if (-not $n) { return 0 }; [int](((& $n.Source -v) -replace '^v(\d+)\..*', '$1')) }
    if ((Get-Major) -ge 20) { Ok "Node.js $(node -v) found"; return }
    Warn 'Node.js 20 or newer is required but was not found.'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is not available to install Node.js automatically. Install the LTS version from https://nodejs.org, open a new PowerShell window, and run this command again.'
    }
    if (-not (Confirm-Yes 'Install Node.js LTS now using winget (OpenJS.NodeJS.LTS)?')) { throw 'Node.js is required. Install it from https://nodejs.org and run this command again.' }
    & winget.exe install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget could not install Node.js (exit $LASTEXITCODE). Install it from https://nodejs.org and run this command again." }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if ((Get-Major) -lt 20) { throw 'Node.js was installed but is not visible yet. Open a NEW PowerShell window and run this command again.' }
    Ok "Node.js $(node -v) installed"
}

function Get-Upstream {   # -> @{ Sha; Message } ; $null when GitHub is unreachable
    if ($UpstreamRef -match '^[0-9a-f]{40}$') { return @{ Sha = $UpstreamRef; Message = '' } }
    try {
        $r = Invoke-RestMethod "https://api.github.com/repos/$UpstreamRepo/commits/$UpstreamRef" -Headers @{ 'User-Agent' = 'Web2API-installer' }
        return @{ Sha = $r.sha; Message = ($r.commit.message -split "`n")[0] }
    } catch { return $null }
}

function Download-Extract([string]$repo, [string]$ref) {   # returns the extracted top folder
    $zip = Join-Path $script:Temp ("{0}.zip" -f ($repo -replace '/', '_'))
    Invoke-WebRequest "https://codeload.github.com/$repo/zip/$ref" -OutFile $zip -UseBasicParsing
    $out = Join-Path $script:Temp ($repo -replace '/', '_')
    Expand-Archive $zip -DestinationPath $out -Force
    (Get-ChildItem $out -Directory | Select-Object -First 1).FullName
}

function Invoke-Logged([string]$what, [string]$exe, [string[]]$argv, [string]$wd) {
    Say "$what ..."
    $o = Join-Path $script:Temp 'o.txt'; $e = Join-Path $script:Temp 'e.txt'
    $p = Start-Process $exe -ArgumentList $argv -WorkingDirectory $wd -NoNewWindow -Wait -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
    Add-Content $script:Log "### $what (exit $($p.ExitCode))"
    Get-Content $o, $e -ErrorAction SilentlyContinue | Add-Content $script:Log
    if ($p.ExitCode -ne 0) {
        Get-Content $o, $e -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Say "    $_" }
        throw "$what failed (exit $($p.ExitCode)). Previous version is untouched. Full log: $($script:Log)"
    }
}

function Build-Upstream([string]$dir) {
    if (-not (Test-Path (Join-Path $dir 'package.json'))) { throw "$UpstreamRepo@$UpstreamRef has no package.json - not a web-to-api build. Previous version is untouched." }
    $pkg = Get-Content (Join-Path $dir 'package.json') -Raw | ConvertFrom-Json
    if ($pkg.name -ne 'web-to-api') { throw "Upstream package is '$($pkg.name)', expected 'web-to-api' - incompatible, aborting." }
    if (-not $pkg.scripts.build) { throw 'Upstream has no "build" script - incompatible, aborting.' }
    $need = if ($pkg.engines.node -match '(\d+)') { [int]$Matches[1] } else { 0 }
    $have = [int](((& node -v) -replace '^v(\d+)\..*', '$1'))
    if ($have -lt $need) { throw "Upstream needs Node.js $need+, found $have. Update Node.js and re-run." }
    $npm = (Get-Command npm.cmd).Source
    $install = if (Test-Path (Join-Path $dir 'package-lock.json')) { 'ci' } else { 'install' }
    Invoke-Logged "npm $install" $npm @($install, '--no-audit', '--no-fund') $dir
    Invoke-Logged 'npm run build' $npm @('run', 'build') $dir
    if (-not (Test-Path (Join-Path $dir 'dist\cli.js'))) { throw 'Build finished but dist\cli.js is missing - upstream layout changed. Previous version is untouched.' }
    # Smoke test: the CLI flags our launcher depends on must still exist.
    $help = (& node (Join-Path $dir 'dist\cli.js') --help 2>$null) | Out-String
    foreach ($flag in '--no-open', '--browser-mode', '--port', '--state-dir', '--chrome-profile') {
        if ($help -notmatch [regex]::Escape($flag)) { throw "Upstream CLI no longer supports $flag - launcher is incompatible with this version. Previous version is untouched." }
    }
    try { Invoke-Logged 'npm prune (runtime dependencies only)' $npm @('prune', '--omit=dev') $dir } catch { Warn 'prune failed; keeping dev dependencies (harmless)' }
}

function Install-Launcher {
    $local = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'scripts\windows\web-to-api-tray.ps1' }
    if ($local -and (Test-Path $local)) { $src = $local }
    else {
        Say "Fetching launcher from $LauncherRepo@$LauncherRef ..."
        $src = Join-Path (Download-Extract $LauncherRepo $LauncherRef) 'scripts\windows\web-to-api-tray.ps1'
        if (-not (Test-Path $src)) { throw "Launcher script not found in $LauncherRepo@$LauncherRef" }
    }
    New-Item -ItemType Directory -Force $LauncherDir | Out-Null
    $newHash = (Get-FileHash $src -Algorithm SHA256).Hash
    if (Test-Path $Launcher) {
        $curHash = (Get-FileHash $Launcher -Algorithm SHA256).Hash
        if ($curHash -eq $newHash) { Ok 'Launcher already current'; return $newHash }
        if ($cfg -and $cfg.launcherSha256 -and $curHash -ne $cfg.launcherSha256) {
            $bak = "$Launcher.bak-$(Get-Date -Format yyyyMMddHHmmss)"
            Copy-Item $Launcher $bak
            Warn "Your launcher had local edits; saved as $bak (re-apply them if you still need them)"
        }
    }
    Copy-Item $src $Launcher -Force
    Ok "Launcher installed: $Launcher"
    $newHash
}

function Complete-Start([string]$foreign) {   # $foreign: port owner measured BEFORE our tray started
    if ($foreign) {
        # Tray was just (re)started; if a foreign process owns the port the tray reports Error and keeps retrying.
        Warn "Port $Port is already in use by $foreign. The tray shows an Error and retries until it is free."
        Warn 'Close that program (or install with -Port <other>) - it is NOT being killed automatically.'
        Write-Summary 'Finished with a port conflict (see warnings above)'
        return
    }
    Say "Waiting for the API to answer on port $Port (first start can take ~30 s) ..."
    $h = Wait-Health 150
    if (-not $h) {
        $err = Join-Path $EffStateDir 'logs\launcher.err.log'
        Warn "API did not become healthy in time. Check the tray icon and logs: $EffStateDir\logs"
        if (Test-Path $err) { Get-Content $err -Tail 8 | ForEach-Object { Say "    $_" } }
        throw 'API health check failed. If this was an update, run again with -Rollback.'
    }
    Ok "Health OK: $($h.status)"
    if ($h.providers) { $h.providers.PSObject.Properties | ForEach-Object { Say ("    {0}: authenticated={1}" -f $_.Name, $_.Value.authenticated) } }
    Write-Summary
}

function Invoke-Install {
    Step 'Checking Node.js'
    Ensure-Node
    New-Item -ItemType Directory -Force $InstallDir, $LogDir | Out-Null
    $script:Log = Join-Path $LogDir ("install-{0}.log" -f (Get-Date -Format yyyyMMdd-HHmmss))
    $script:Temp = Join-Path ([IO.Path]::GetTempPath()) ("web2api-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force $script:Temp | Out-Null

    Step 'Launcher'
    $launcherHash = Install-Launcher

    Step "Upstream $UpstreamRepo@$UpstreamRef"
    $up = Get-Upstream
    $installedSha = if ($cfg) { $cfg.upstreamSha } else { $null }
    $haveApp = Test-Path (Join-Path $AppDir 'dist\cli.js')
    $changed = $false
    if (-not $up) {
        if (-not $haveApp) { throw "Cannot reach GitHub (api.github.com) and nothing is installed yet. Check your connection/proxy and retry." }
        Warn 'Cannot reach GitHub to check for updates; keeping the installed build.'
        $up = @{ Sha = $installedSha; Message = '' }
    } elseif ($haveApp -and $installedSha -eq $up.Sha -and -not $Force) {
        Ok "Upstream unchanged ($($up.Sha.Substring(0, 7))); nothing to rebuild"
    } else {
        $from = if ($installedSha) { $installedSha.Substring(0, 7) } else { 'none' }
        Say "Upstream: $from -> $($up.Sha.Substring(0, 7))  $($up.Message)"
        Remove-Tree $AppNew
        $src = Download-Extract $UpstreamRepo $up.Sha
        Move-Item $src $AppNew
        Step 'Building (npm ci + build + smoke test)'
        try { Build-Upstream $AppNew } catch { Remove-Tree $AppNew; throw }
        $changed = $true
    }

    Step 'Switching over'
    Invoke-Tray '-Stop'   # closes the tray, which stops the API cleanly; no-op if not running (also frees the files before the swap)
    $prevSha = if ($cfg) { $cfg.previousSha } else { $null }
    if ($changed) {
        if (Test-Path $AppDir) {
            Remove-Tree $AppPrev
            Rename-Item $AppDir 'app.prev'
            $prevSha = $installedSha
        }
        try { Rename-Item $AppNew 'app' } catch {
            if ((Test-Path $AppPrev) -and -not (Test-Path $AppDir)) { Rename-Item $AppPrev 'app' }   # restore
            throw
        }
        Ok 'New build is live'
    }
    $new = [ordered]@{
        port = $Port; stateDir = $StateDir; chromeProfile = $ChromeProfile
        upstreamRepo = $UpstreamRepo
        upstreamSha = $up.Sha; previousSha = $prevSha
        launcherSha256 = $launcherHash; updatedAt = (Get-Date).ToString('s')
    }
    Save-Config $new
    $script:cfg = [pscustomobject]$new

    Step 'Startup and launch'
    $foreign = Get-PortOwner
    $hasStartup = Test-Path $StartupLnk
    $wantStartup = $false
    if (-not $NoStartup) {
        $wantStartup = if ($hasStartup) { $true } else { Confirm-Yes "Start web-to-api automatically when you sign in to Windows?" }
    }
    if ($wantStartup) { Invoke-Tray '-Install -Yes'; Ok 'Startup entry set; tray launched' }
    else { Start-Tray; Ok 'Tray launched (startup entry left as it was; toggle "Start with Windows" in the tray menu any time)' }
    Complete-Start $foreign
}

# ================= main =================
$created = $false
$lock = New-Object Threading.Mutex($true, 'Local\Web2API-installer', [ref]$created)
$code = 0
try {
    if (-not $created) { throw 'Another Web2API installer is already running.' }
    Write-Host "Web2API installer  (InstallDir: $InstallDir, port $Port)" -ForegroundColor Cyan
    if ($Uninstall) { Invoke-Uninstall }
    elseif ($Rollback) { Invoke-Rollback }
    else { Invoke-Install }
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    $code = 1
} finally {
    if ($script:Temp -and (Test-Path $script:Temp)) { Remove-Item $script:Temp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($created) { $lock.ReleaseMutex() }
}
if ($PSCommandPath) { exit $code } else { $global:LASTEXITCODE = $code }
