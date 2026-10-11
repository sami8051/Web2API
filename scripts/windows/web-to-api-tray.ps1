<#
.SYNOPSIS
  Windows tray launcher for web-to-api: runs the API hidden, restarts it on crash.

.DESCRIPTION
  Run with no switches to start the tray app (it starts the API immediately).
    -Install    ask consent (-Yes skips the question), add a Startup-folder shortcut, start the tray now
    -Uninstall  remove the Startup shortcut and close a running tray (stops the API)
    -Stop       close a running tray (stops the API) but keep the startup entry
  -AppDir points at the web-to-api checkout/build; default is two levels above this script.
#>
[CmdletBinding()]
param(
    [int]$Port = 3456,
    [string]$StateDir = (Join-Path $env:USERPROFILE '.web-to-api'),
    [string]$ChromeProfile = '',
    [string]$AppDir = '',
    [string[]]$CliArgs = @(),
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Stop,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Root       = if ($AppDir) { $AppDir } else { (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path }
if ($ChromeProfile) { $CliArgs = @($CliArgs) + @('--chrome-profile', $ChromeProfile) }
$LogDir     = Join-Path $StateDir 'logs'
$OutLog     = Join-Path $LogDir 'launcher.out.log'
$ErrLog     = Join-Path $LogDir 'launcher.err.log'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'web-to-api.lnk'
$Url        = "http://127.0.0.1:$Port"
$QuitName   = 'Local\web-to-api-tray-quit'
$MutexName  = 'Local\web-to-api-tray'
$StartupGraceSec = 120   # API must open its port within this long, else it is killed and retried

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace W -Name K -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern bool AttachConsole(uint pid);
[DllImport("kernel32.dll")] public static extern bool FreeConsole();
[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
[DllImport("kernel32.dll")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g);
'@

# Arguments that make a fresh tray process behave like this one (startup shortcut, -Install).
function Get-SelfArgs {
    $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" -Port $Port -StateDir `"$StateDir`""
    if ($AppDir) { $a += " -AppDir `"$AppDir`"" }
    if ($ChromeProfile) { $a += " -ChromeProfile `"$ChromeProfile`"" }
    $a
}

# ---- startup shortcut (the "Start with Windows" switch) ----
function Test-Startup { Test-Path $StartupLnk }
function Set-Startup([bool]$On) {
    if ($On) {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($StartupLnk)
        $s.TargetPath = (Get-Command powershell.exe).Source
        $s.Arguments = Get-SelfArgs
        $s.WorkingDirectory = $Root
        $s.WindowStyle = 7   # minimized: shortest possible console flash at sign-in
        $s.Description = 'web-to-api tray launcher'
        $s.Save()
    } elseif (Test-Startup) {
        Remove-Item $StartupLnk -Force
    }
}

# ---- what to run: package.json decides, nothing is assumed ----
function Get-ApiCommand {
    $pkg = Get-Content (Join-Path $Root 'package.json') -Raw | ConvertFrom-Json
    $apiArgs = @('--no-open', '--browser-mode', 'launch', '--port', "$Port", '--state-dir', $StateDir) + $CliArgs
    $bin = $null
    if ($pkg.bin) { $bin = if ($pkg.bin -is [string]) { $pkg.bin } else { @($pkg.bin.PSObject.Properties)[0].Value } }
    elseif ($pkg.main) { $bin = $pkg.main }
    $binPath = if ($bin) { Join-Path $Root $bin }
    $binFresh = $false
    if ($binPath -and (Test-Path $binPath)) {
        $newestSrc = Get-ChildItem (Join-Path $Root 'src') -Recurse -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $binFresh = (-not $newestSrc) -or ((Get-Item $binPath).LastWriteTime -ge $newestSrc.LastWriteTime)
    }
    $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
    $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if ($pkg.scripts.start -and $npm) {
        return @{ Exe = $npm; Args = @('run', 'start', '--') + $apiArgs; Graceful = $false; Label = 'npm run start' }
    }
    if ($binFresh -and $node) {   # direct node = no wrapper process, so Ctrl+C reaches it for a clean shutdown
        return @{ Exe = $node; Args = @($binPath) + $apiArgs; Graceful = $true; Label = "node $bin" }
    }
    if ($pkg.scripts.dev -and $npm) {
        return @{ Exe = $npm; Args = @('run', 'dev', '--') + $apiArgs; Graceful = $false; Label = 'npm run dev' }
    }
    throw 'No start/dev script and no fresh built entry in package.json (run: npm run build)'
}

# ---- process control ----
$script:Proc = $null
$script:Graceful = $false
$script:Want = $false            # user wants it running (false after Stop/Exit)
$script:State = 'Stopped'        # Stopped | Starting | Running | Error
$script:Detail = ''
$script:StartedAt = [datetime]::MinValue
$script:RetryAt = [datetime]::MinValue
$script:Backoff = 2
$script:Tray = $null

function Test-PortOpen {
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync('127.0.0.1', $Port).Wait(500) -and $c.Connected } catch { return $false } finally { $c.Close() }
}

function Set-Status([string]$state, [string]$detail = '') {
    $changed = $script:State -ne $state
    $script:State = $state; $script:Detail = $detail
    if ($script:Tray) { Update-Ui $changed }
}

function Start-Api {
    $owner = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($owner) {   # the CLI would silently pick another port; keep 3456 or fail loudly
        $name = (Get-Process -Id $owner.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        Fail-Start "Port $Port in use by $name (PID $($owner.OwningProcess))"
        return
    }
    try { $cmd = Get-ApiCommand } catch { Fail-Start $_.Exception.Message; return }
    New-Item -ItemType Directory -Force $LogDir | Out-Null
    foreach ($f in $OutLog, $ErrLog) { if (Test-Path $f) { Move-Item $f ($f -replace '\.log$', '.prev.log') -Force } }
    $script:Proc = Start-Process $cmd.Exe -ArgumentList $cmd.Args -WorkingDirectory $Root -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -PassThru
    $null = $script:Proc.Handle   # keep the handle so ExitCode is readable later
    $script:Graceful = $cmd.Graceful
    $script:StartedAt = Get-Date
    Set-Status 'Starting' $cmd.Label
}

function Fail-Start([string]$msg) {
    $script:RetryAt = (Get-Date).AddSeconds($script:Backoff)
    $msg = "$msg; retry in $($script:Backoff)s"
    $script:Backoff = [Math]::Min($script:Backoff * 2, 60)
    Set-Status 'Error' $msg
}

function Stop-Api {
    $script:Want = $false
    $p = $script:Proc; $script:Proc = $null
    if ($p -and -not $p.HasExited) {
        Set-Status 'Stopped' 'stopping...'
        if ($script:Graceful) {   # Ctrl+C -> the CLI's SIGINT handler closes Chrome and flushes the profile
            [void][W.K]::FreeConsole()
            if ([W.K]::AttachConsole([uint32]$p.Id)) {
                [void][W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
                [void][W.K]::GenerateConsoleCtrlEvent(0, 0)
                Start-Sleep -Milliseconds 200
                [void][W.K]::FreeConsole()
                [void][W.K]::SetConsoleCtrlHandler([IntPtr]::Zero, $false)
            }
            [void]$p.WaitForExit(8000)
        }
        if (-not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null }   # whole tree, no orphans
        [void]$p.WaitForExit(5000)
    }
    $script:Backoff = 2
    Set-Status 'Stopped'
}

function Start-Requested { $script:Want = $true; $script:Backoff = 2; $script:RetryAt = [datetime]::MinValue; Tick }
function Restart-Api { Stop-Api; Start-Requested }

# Called by the timer every 2s: reconcile "what the user wants" with "what is running".
function Tick {
    if (-not $script:Want) { return }
    $p = $script:Proc
    if ($p -and -not $p.HasExited) {
        if (Test-PortOpen) {
            if ($script:State -ne 'Running') { Set-Status 'Running' $Url }
            if (((Get-Date) - $script:StartedAt).TotalSeconds -gt 60) { $script:Backoff = 2 }   # stable: forgive past crashes
        } elseif ($script:State -ne 'Starting' -and $script:State -ne 'Error') {
            Set-Status 'Starting' 'port not answering'
            $script:StartedAt = Get-Date
        } elseif (((Get-Date) - $script:StartedAt).TotalSeconds -gt $StartupGraceSec) {
            & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null   # hung: next tick restarts it
        }
        return
    }
    if ($p) {   # it just died on its own
        $script:Proc = $null
        Fail-Start "Crashed (exit $($p.ExitCode))"
    }
    if ((Get-Date) -ge $script:RetryAt) { Start-Api }
}

# ---- UI ----
function New-DotIcon([Drawing.Color]$color) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.FillEllipse((New-Object Drawing.SolidBrush $color), 3, 3, 26, 26)
    $g.DrawEllipse((New-Object Drawing.Pen ([Drawing.Color]::FromArgb(90, 0, 0, 0)), 2), 3, 3, 26, 26)
    $g.Dispose()
    [Drawing.Icon]::FromHandle($bmp.GetHicon())   # 4 icons live for the process lifetime; handles are not leaked per update
}

function Update-Ui([bool]$stateChanged) {
    $s = $script:State
    $script:Tray.Icon = $script:Icons[$s]
    $line = if ($script:Detail) { "$s - $($script:Detail)" } else { $s }
    $script:MiStatus.Text = "web-to-api: $line"
    $tip = "web-to-api: $line"
    $script:Tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip }
    $script:MiStart.Enabled = -not $script:Want
    $script:MiStop.Enabled = $script:Want
    $script:MiStartup.Checked = Test-Startup
    if ($stateChanged -and $s -eq 'Error') {
        $script:Tray.ShowBalloonTip(5000, 'web-to-api', $script:Detail, 'Warning')
    }
}

function Exit-App {
    Stop-Api
    $script:Tray.Visible = $false
    $script:Tray.Dispose()
    $script:Ctx.ExitThread()
}

# ---- entry points ----
# Ask a running tray to exit (it stops the API first) and wait until it is gone.
function Request-TrayQuit {
    $h = $null
    if (-not [Threading.EventWaitHandle]::TryOpenExisting($QuitName, [ref]$h)) { return $false }
    [void]$h.Set()
    for ($i = 0; $i -lt 90; $i++) {
        $m = $null
        if (-not [Threading.Mutex]::TryOpenExisting($MutexName, [ref]$m)) { break }
        $m.Dispose(); Start-Sleep -Milliseconds 500
    }
    $true
}

if ($Stop -or $Uninstall) {
    if ($Uninstall) { Set-Startup $false }
    if (Request-TrayQuit) { Write-Host 'Tray closed (it stopped the API first).' } else { Write-Host 'Tray was not running.' }
    if ($Uninstall) { Write-Host 'Startup disabled. Nothing else was changed.' }
    return
}
if ($Install) {
    if (-not $Yes) {
        $ans = Read-Host "Start the web-to-api tray (API on port $Port) automatically when you sign in to Windows? [Y/n]"
        if ($ans -match '^(n|no)$') { Write-Host 'Cancelled, startup not changed.'; return }
    }
    Set-Startup $true
    Write-Host "Startup enabled: $StartupLnk"
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (Get-SelfArgs)
    Write-Host 'Tray launched - look for the dot near the clock (it may be under the ^ overflow arrow).'
    return
}
if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced (tests): functions only, no UI

$created = $false
$mutex = New-Object Threading.Mutex($true, $MutexName, [ref]$created)
if (-not $created) { return }   # already running

$quit = New-Object Threading.EventWaitHandle($false, 'ManualReset', $QuitName)
$script:Icons = @{
    Stopped  = New-DotIcon ([Drawing.Color]::Gray)
    Starting = New-DotIcon ([Drawing.Color]::Orange)
    Running  = New-DotIcon ([Drawing.Color]::LimeGreen)
    Error    = New-DotIcon ([Drawing.Color]::Red)
}
$menu = New-Object Windows.Forms.ContextMenuStrip
function Add-Item([string]$text, [scriptblock]$onClick) {
    $i = $menu.Items.Add($text); if ($onClick) { $i.add_Click($onClick) }; $i
}
$script:MiStatus = Add-Item 'web-to-api' $null; $script:MiStatus.Enabled = $false
[void]$menu.Items.Add('-')
$script:MiStart = Add-Item 'Start' { Start-Requested }
$script:MiStop = Add-Item 'Stop' { Stop-Api }
[void](Add-Item 'Restart' { Restart-Api })
[void]$menu.Items.Add('-')
[void](Add-Item 'Open Dashboard' { Start-Process $Url })
[void](Add-Item 'Open API (/v1/models)' { Start-Process "$Url/v1/models" })
[void](Add-Item 'Open Logs' { New-Item -ItemType Directory -Force $LogDir | Out-Null; Start-Process explorer.exe $LogDir })
[void]$menu.Items.Add('-')
$script:MiStartup = Add-Item 'Start with Windows' { Set-Startup (-not (Test-Startup)); Update-Ui $false }
[void]$menu.Items.Add('-')
[void](Add-Item 'Exit' { Exit-App })

$script:Ctx = New-Object Windows.Forms.ApplicationContext
$script:Tray = New-Object Windows.Forms.NotifyIcon
$script:Tray.ContextMenuStrip = $menu
$script:Tray.add_DoubleClick({ Start-Process $Url })
$script:Tray.Visible = $true
Update-Ui $false

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 2000
$timer.add_Tick({
    try {
        if ($quit.WaitOne(0)) { Exit-App; return }
        Tick
    } catch { Set-Status 'Error' $_.Exception.Message }
})
$timer.Start()
[Microsoft.Win32.SystemEvents]::add_SessionEnding({ Exit-App })

try {
    Start-Requested
    [Windows.Forms.Application]::Run($script:Ctx)
} finally {
    $timer.Stop()
    if ($script:Proc -and -not $script:Proc.HasExited) { Stop-Api }
    $mutex.ReleaseMutex()
}
