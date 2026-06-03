# ProximityLock.ps1 -- Main entry
#
# Modern Windows Bluetooth proximity auto-lock.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\ProximityLock.ps1
#   powershell -ExecutionPolicy Bypass -File .\ProximityLock.ps1 -ResetDevice
#   powershell -ExecutionPolicy Bypass -File .\ProximityLock.ps1 -ConfigPath .\custom-config.json

[CmdletBinding()]
param(
    [string] $ConfigPath,
    [switch] $ResetDevice,
    [switch] $NoTray,         # for headless testing
    [switch] $DebugLog
)

# --- Locate own directory ---
$AppRoot = $null
if ($PSCommandPath) { $AppRoot = Split-Path -Parent $PSCommandPath }
elseif ($MyInvocation.MyCommand.Path) { $AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
else { $AppRoot = (Get-Location).Path }

if (-not $ConfigPath) { $ConfigPath = Join-Path $AppRoot 'config.json' }

# --- Dot-source modules ---
. (Join-Path $AppRoot 'lib\I18n.ps1')
. (Join-Path $AppRoot 'lib\Logger.ps1')
. (Join-Path $AppRoot 'lib\Config.ps1')
. (Join-Path $AppRoot 'lib\WinRT.ps1')
. (Join-Path $AppRoot 'lib\Bluetooth.ps1')
. (Join-Path $AppRoot 'lib\Lock.ps1')
. (Join-Path $AppRoot 'lib\Session.ps1')
. (Join-Path $AppRoot 'lib\Idle.ps1')
if (-not $NoTray) { . (Join-Path $AppRoot 'lib\Tray.ps1') }

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing      -ErrorAction Stop

# ============================================================================
# Config bootstrap
# ============================================================================

function Test-HasInteractiveConsole {
    try {
        if ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) { return $true }
    } catch { }
    return $false
}

function Select-DeviceCli {
    param([Parameter(Mandatory)] $Devices)
    Write-Host ""
    Write-Host (Get-LocaleString 'CliHeader') -ForegroundColor Cyan
    Write-Host (Get-LocaleString 'CliVisible')
    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        Write-Host ("  [{0}] {1}   ({2})" -f ($i + 1), $d.Name, $d.Kind)
    }
    while ($true) {
        $sel = Read-Host (Get-LocaleString 'CliPrompt' $Devices.Count)
        if ($sel -match '^\d+$') {
            $n = [int]$sel
            if ($n -ge 1 -and $n -le $Devices.Count) { return $Devices[$n - 1] }
        }
        Write-Host (Get-LocaleString 'CliInvalid') -ForegroundColor Yellow
    }
}

function Select-DeviceForm {
    param([Parameter(Mandatory)] $Devices)
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = Get-LocaleString 'SelectDeviceTitle'
    $form.Size          = New-Object System.Drawing.Size 460, 360
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox   = $false
    $form.MinimizeBox   = $false
    $form.TopMost       = $true

    $label = New-Object System.Windows.Forms.Label
    $label.Text     = Get-LocaleString 'SelectDeviceLabel'
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point 12, 12
    $form.Controls.Add($label)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point 12, 40
    $list.Size     = New-Object System.Drawing.Size 420, 220
    foreach ($d in $Devices) {
        [void]$list.Items.Add(("{0}    [{1}]" -f $d.Name, $d.Kind))
    }
    if ($list.Items.Count -gt 0) { $list.SelectedIndex = 0 }
    $form.Controls.Add($list)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text     = Get-LocaleString 'BtnOk'
    $btnOk.Location = New-Object System.Drawing.Point 256, 275
    $btnOk.Size     = New-Object System.Drawing.Size 80, 28
    $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.AcceptButton = $btnOk
    $form.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = Get-LocaleString 'BtnCancel'
    $btnCancel.Location = New-Object System.Drawing.Point 350, 275
    $btnCancel.Size     = New-Object System.Drawing.Size 80, 28
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.CancelButton  = $btnCancel
    $form.Controls.Add($btnCancel)

    if ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $list.SelectedIndex -ge 0) {
        return $Devices[$list.SelectedIndex]
    }
    return $null
}

function Invoke-FirstRunSetup {
    param([Parameter(Mandatory)][string] $ConfigPath)

    Write-Host (Get-LocaleString 'FirstRunSetup') -ForegroundColor Cyan
    $devs = @(Get-PairedBluetoothDevices)
    if ($devs.Count -eq 0) {
        throw (Get-LocaleString 'NoDevicesErr')
    }
    $chosen = $null
    if (Test-HasInteractiveConsole) {
        $chosen = Select-DeviceCli -Devices $devs
    } else {
        $chosen = Select-DeviceForm -Devices $devs
        if (-not $chosen) { throw "Device selection cancelled" }
    }
    Write-Host (Get-LocaleString 'SelectedDevice' @($chosen.Name, $chosen.Kind)) -ForegroundColor Green

    $cfg = Get-DefaultConfig
    $cfg.device.id               = $chosen.Id
    $cfg.device.name             = $chosen.Name
    $cfg.device.kind             = $chosen.Kind
    $cfg.device.bluetoothAddress = if ($chosen.BluetoothAddress) { [string]$chosen.BluetoothAddress } else { $null }
    Write-Config -Path $ConfigPath -Config $cfg
    Write-Host (Get-LocaleString 'SavedConfig' $ConfigPath) -ForegroundColor Green
    return $cfg
}

# ============================================================================
# State machine
# ============================================================================

$script:InstanceMutex = $null

function Test-AndAcquireSingleInstance {
    <#
        Use a named Mutex to ensure only one Proximity Lock runs per user
        session. Returns $true if we acquired it (we're the first instance),
        $false if another instance is already running.
        Uses Local\ namespace (per-session) so each user can have their own.
    #>
    $createdNew = $false
    try {
        $script:InstanceMutex = New-Object System.Threading.Mutex(
            $true, 'Local\ProximityLock_SingleInstance', [ref]$createdNew)
    } catch {
        Write-Host "Failed to create instance mutex: $($_.Exception.Message)" -ForegroundColor Yellow
        return $true   # fail open: if the guard breaks, don't block legitimate start
    }
    if (-not $createdNew) {
        try { $script:InstanceMutex.Dispose() } catch { }
        $script:InstanceMutex = $null
        return $false
    }
    return $true
}

$script:App = [pscustomobject]@{
    Config            = $null
    AppRoot           = $AppRoot
    ConfigPath        = $ConfigPath
    Enabled           = $true
    State             = 'Idle'           # Idle | Monitoring | Countdown | Locked | Disabled
    CountdownRemain   = 0
    CountdownTimer    = $null
    PollTimer         = $null
    RssiBelowSince    = $null            # DateTime when RSSI first went below threshold
    DisconnectedSince = $null            # DateTime when BT first reported disconnected (sustain debounce)
    ConnectedSince    = $null            # DateTime of current continuous-connect streak; reset on any failure
    GraceUntil        = $null            # Lock suppression deadline after start/unlock
    LastSnapshot      = $null
    ProbeFailureCount = 0                # consecutive failed classic probes; reset on success
    ExitRequested     = $false
    ScreenWakeSent    = $false
}

function Set-GracePeriod {
    param([string] $Reason)
    $sec = [int]$script:App.Config.lock.gracePeriodSeconds
    if ($sec -le 0) { $script:App.GraceUntil = $null; return }
    $script:App.GraceUntil = (Get-Date).AddSeconds($sec)
    Write-Log INFO 'App' ("Grace period armed: {0}s (until {1}). Reason: {2}" -f `
        $sec, $script:App.GraceUntil.ToString('HH:mm:ss'), $Reason)
}

function Set-AppState {
    param([Parameter(Mandatory)] [string] $NewState)
    if ($script:App.State -eq $NewState) { return }
    Write-Log INFO 'State' ("{0} -> {1}" -f $script:App.State, $NewState)
    $script:App.State = $NewState
    if ($NewState -eq 'Locked') {
        $script:App.ScreenWakeSent = $false
    }
    if (-not $NoTray) {
        $devName = if ($script:App.Config.device.name) { $script:App.Config.device.name } else { '(none)' }
        $extra   = if ($NewState -eq 'Countdown') { "$($script:App.CountdownRemain)s" } else { '' }
        $conn    = if ($script:App.LastSnapshot) { $script:App.LastSnapshot.Connected } else { $true }
        Update-TrayStatus -State $NewState -DeviceName $devName -ExtraText $extra -DeviceConnected $conn
    }
}

function Update-ConnectionTracking {
    # Update ConnectedSince based on a fresh snapshot and return whether the
    # link is stable enough to trust as "device present". A single successful
    # probe on a flaky classic-BT link doesn't count 鈥?we require the connect
    # streak to last reconnectStableSeconds before clearing sustain timers or
    # cancelling a countdown.
    param([Parameter(Mandatory)] $Snapshot)
    if ($Snapshot.Connected) {
        if (-not $script:App.ConnectedSince) { $script:App.ConnectedSince = Get-Date }
        $stableSec = ((Get-Date) - $script:App.ConnectedSince).TotalSeconds
        $threshold = [int]$script:App.Config.monitor.reconnectStableSeconds
        if ($threshold -lt 0) { $threshold = 0 }
        return [bool]($stableSec -ge $threshold)
    }
    $script:App.ConnectedSince = $null
    return $false
}

function Start-Countdown {
    param([string] $Reason)
    $delay = [int]$script:App.Config.lock.delaySeconds
    if ($delay -lt 1) { $delay = 1 }
    $script:App.CountdownRemain = $delay
    Set-AppState 'Countdown'
    Write-Log INFO 'Countdown' "Starting ${delay}s countdown. Reason: $Reason"

    if (-not $NoTray) {
        Show-TrayBalloon -Title (Get-LocaleString 'LockWarningTitle') -Message (Get-LocaleString 'LockWarningMessage' @($Reason, $delay)) -Kind Warning -TimeoutMs 5000
    }

    if ($script:App.CountdownTimer) { $script:App.CountdownTimer.Stop() }
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        try {
            $script:App.CountdownRemain -= 1
            Write-Log DEBUG 'Countdown' ("tick: {0}s remaining" -f $script:App.CountdownRemain)

            # Mid-countdown: if user came back to keyboard/mouse, cancel.
            $requireIdle = [int]$script:App.Config.lock.requireIdleSeconds
            if ($requireIdle -gt 0) {
                $idleSec = Get-IdleSeconds
                if ($idleSec -ne $null -and $idleSec -lt $requireIdle) {
                    $script:App.CountdownTimer.Stop()
                    Write-Log WARN 'Countdown' ("User activity during countdown (idle={0:N0}s); cancelling lock" -f $idleSec)
                    Set-AppState 'Monitoring'
                    return
                }
            }

            # Mid-countdown: check whether device has reconnected (cancellation)
            if ($script:App.Config.lock.cancelOnReconnect) {
                $useProbe = ([bool]$script:App.Config.monitor.activeProbeEnabled)
                $snap = Get-BluetoothStatusSnapshot -ActiveProbe $useProbe
                $script:App.LastSnapshot = $snap
                $stableConnected = Update-ConnectionTracking -Snapshot $snap
                $stillLost = -not $stableConnected
                # If RSSI is back above threshold, treat that as recovery even
                # when ConnectionStatus still says disconnected (classic BT
                # ConnectionStatus updates lazily and is often stale).
                if ($script:App.Config.monitor.useRssi -and $snap.Rssi -ne $null `
                        -and $snap.Rssi -ge [int]$script:App.Config.monitor.rssiThresholdDbm) {
                    $stillLost = $false
                }
                if (-not $stillLost) {
                    $script:App.CountdownTimer.Stop()
                    $script:App.RssiBelowSince    = $null
                    $script:App.DisconnectedSince = $null
                    Write-Log WARN 'Countdown' "Device reconnected/signal recovered during countdown; cancelling lock"
                    Set-AppState 'Monitoring'
                    return
                }
            }

            if (-not $NoTray) {
                $devName = $script:App.Config.device.name
                Update-TrayStatus -State 'Countdown' -DeviceName $devName -ExtraText ("{0}s" -f $script:App.CountdownRemain)
            }

            if ($script:App.CountdownRemain -le 0) {
                $script:App.CountdownTimer.Stop()
                Invoke-LockSequence
            }
        } catch {
            Write-Log ERROR 'Countdown' "Tick handler failed: $($_.Exception.Message)"
        }
    })
    $script:App.CountdownTimer = $timer
    $timer.Start()
}

function Start-HookAsync {
    <#
        Run a hook script in a background Start-Job. Before launching the new
        job, sweep any finished prior hook jobs so they don't accumulate in
        $psSession.Jobs over the lifetime of the program. Hook jobs are tagged
        with a 'ProxLockHook_' name prefix so we only touch our own.
    #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $HookName
    )

    foreach ($stale in (Get-Job | Where-Object { $_.Name -like 'ProxLockHook_*' -and $_.State -ne 'Running' })) {
        try {
            Receive-Job -Job $stale -ErrorAction SilentlyContinue | Out-Null
            Remove-Job  -Job $stale -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    $params = @{
        ScriptPath     = $ScriptPath
        HookName       = $HookName
        TimeoutSeconds = [int]$script:App.Config.hooks.timeoutSeconds
        RunHidden      = [bool]$script:App.Config.hooks.runHidden
    }
    $jobName = "ProxLockHook_{0}_{1}" -f $HookName, ([guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](Start-Job -Name $jobName -ScriptBlock {
        param($AppRoot, $ParamsJson)
        . (Join-Path $AppRoot 'lib\Logger.ps1')
        . (Join-Path $AppRoot 'lib\Config.ps1')
        . (Join-Path $AppRoot 'lib\Lock.ps1')
        $cfgPath = Join-Path $AppRoot 'config.json'
        $cfg = Read-Config -Path $cfgPath
        $logDir = Resolve-PathRelative -BasePath $AppRoot -InputPath $cfg.logging.directory
        Initialize-Logger -Directory $logDir -MinLevel $cfg.logging.level -EchoToConsole $false
        $p = $ParamsJson | ConvertFrom-Json
        Invoke-HookScript -ScriptPath $p.ScriptPath -HookName $p.HookName -TimeoutSeconds $p.TimeoutSeconds -RunHidden $p.RunHidden
    } -ArgumentList $script:App.AppRoot, ($params | ConvertTo-Json -Compress))
}

function Clear-HookJobs {
    foreach ($j in (Get-Job | Where-Object { $_.Name -like 'ProxLockHook_*' })) {
        try {
            if ($j.State -eq 'Running') { Stop-Job -Job $j -ErrorAction SilentlyContinue }
            Receive-Job -Job $j -ErrorAction SilentlyContinue | Out-Null
            Remove-Job  -Job $j -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Invoke-LockSequence {
    Write-Log INFO 'Lock' "Countdown elapsed, executing lock sequence"
    # Lock first, then run hook in parallel (hook may take a while)
    [void](Invoke-WorkstationLock)
    Set-AppState 'Locked'

    $hook = $script:App.Config.hooks.onLock
    $resolved = Resolve-PathRelative -BasePath $script:App.AppRoot -InputPath $hook
    if ($resolved) {
        Start-HookAsync -ScriptPath $resolved -HookName 'OnLock'
    }
}

function Invoke-UnlockHook {
    $hook = $script:App.Config.hooks.onUnlock
    $resolved = Resolve-PathRelative -BasePath $script:App.AppRoot -InputPath $hook
    if (-not $resolved) { return }
    Start-HookAsync -ScriptPath $resolved -HookName 'OnUnlock'
}$script:PollTickActive = $false

function Invoke-PollTick {
    if ($script:PollTickActive) { return }
    if (-not $script:App.Enabled) { return }
    if ($script:App.State -eq 'Countdown') { return }   # countdown handles its own polling

    # If Locked, we only poll to detect reconnection and wake screen
    if ($script:App.State -eq 'Locked') {
        if ($script:App.ScreenWakeSent) { return }
        $script:PollTickActive = $true
        try {
            $useProbe = ([bool]$script:App.Config.monitor.activeProbeEnabled)
            $snap = Get-BluetoothStatusSnapshot -ActiveProbe $useProbe
            $script:App.LastSnapshot = $snap
            $stableConnected = Update-ConnectionTracking -Snapshot $snap
            
            $recovered = $stableConnected
            if ($script:App.Config.monitor.useRssi -and $snap.Rssi -ne $null `
                    -and $snap.Rssi -ge [int]$script:App.Config.monitor.rssiThresholdDbm) {
                $recovered = $true
            }
            if ($recovered) {
                Invoke-ScreenWake
                $script:App.ScreenWakeSent = $true
            }
        } catch {
            Write-Log ERROR 'Poll' "Locked poll tick failed: $($_.Exception.Message)"
        } finally {
            $script:PollTickActive = $false
        }
        return
    }

    $script:PollTickActive = $true
    try {
        $snap = Get-BluetoothStatusSnapshot
        $script:App.LastSnapshot = $snap

        # If classic cache says disconnected for a few seconds, run one SDP
        # probe to wake the BT stack before letting sustain accumulate further.
        if (-not $snap.Connected `
                -and $snap.DeviceKind -eq 'classic' `
                -and [bool]$script:App.Config.monitor.activeProbeEnabled) {
            $probeAfter = [int]$script:App.Config.monitor.activeProbeAfterSeconds
            $disconnSec = if ($script:App.DisconnectedSince) {
                ((Get-Date) - $script:App.DisconnectedSince).TotalSeconds
            } else { 0 }
            if ($disconnSec -ge $probeAfter) {
                Write-Log DEBUG 'Poll' ("Running SDP active probe (sustained {0:N0}s, threshold {1}s)" -f $disconnSec, $probeAfter)
                $snap = Get-BluetoothStatusSnapshot -ActiveProbe $true
                $script:App.LastSnapshot = $snap
                if ($snap.Connected) {
                    if ($script:App.ProbeFailureCount -gt 0) {
                        Write-Log INFO 'Poll' ("Active probe recovered after {0} consecutive failures" -f $script:App.ProbeFailureCount)
                        $script:App.ProbeFailureCount = 0
                    }
                } else {
                    $script:App.ProbeFailureCount += 1
                    if ($script:App.ProbeFailureCount -eq 1) {
                        Write-Log INFO 'Poll' "Active probe failed (device unreachable); will retry silently"
                    }
                }
            }
        }

        if ($snap.Rssi -ne $null) {
            Write-Log DEBUG 'Poll' ("connected={0} rssi={1}dBm probe={2}" -f $snap.Connected, $snap.Rssi, $snap.ProbeUsed)
        } else {
            Write-Log DEBUG 'Poll' ("connected={0} rssi=n/a probe={1}" -f $snap.Connected, $snap.ProbeUsed)
        }

        # Update tray status to show connection status
        if (-not $NoTray -and $script:App.State -eq 'Monitoring') {
            $devName = if ($script:App.Config.device.name) { $script:App.Config.device.name } else { '(none)' }
            Update-TrayStatus -State 'Monitoring' -DeviceName $devName -DeviceConnected $snap.Connected
        }

        $shouldTrigger = $false
        $reason = $null

        # Update connect-streak tracker. A single successful probe on a
        # flaky classic-BT link does NOT clear sustain timers — we need
        # reconnectStableSeconds of continuous connection to count.
        $stableConnected = Update-ConnectionTracking -Snapshot $snap

        # --- Disconnected debounce: classic BT ConnectionStatus is unreliable,
        #     so require N consecutive seconds of "disconnected" before acting. ---
        if (-not $snap.Connected) {
            $disconnectSustain = [int]$script:App.Config.monitor.disconnectedSustainSeconds
            if (-not $script:App.DisconnectedSince) {
                $script:App.DisconnectedSince = Get-Date
                Write-Log DEBUG 'Poll' ("BT shows disconnected; starting sustain timer ({0}s)" -f $disconnectSustain)
            }
            $sustainedSec = ((Get-Date) - $script:App.DisconnectedSince).TotalSeconds
            if ($sustainedSec -ge $disconnectSustain) {
                $shouldTrigger = $true
                $reason = "Bluetooth sustained disconnected for $([int]$sustainedSec)s"
            }
        } else {
            if ($stableConnected -and $script:App.DisconnectedSince) {
                $stableSec = ((Get-Date) - $script:App.ConnectedSince).TotalSeconds
                Write-Log DEBUG 'Poll' ("BT stable for {0:N0}s; clearing disconnect sustain timer" -f $stableSec)
                $script:App.DisconnectedSince = $null
            }

            if ($script:App.Config.monitor.useRssi -and $snap.Rssi -ne $null) {
                $threshold = [int]$script:App.Config.monitor.rssiThresholdDbm
                if ($snap.Rssi -lt $threshold) {
                    if (-not $script:App.RssiBelowSince) {
                        $script:App.RssiBelowSince = Get-Date
                        Write-Log DEBUG 'Poll' ("RSSI below threshold ({0} < {1}); starting sustain timer" -f $snap.Rssi, $threshold)
                    }
                    $sustained = ((Get-Date) - $script:App.RssiBelowSince).TotalSeconds
                    if ($sustained -ge [int]$script:App.Config.monitor.rssiSustainSeconds) {
                        $shouldTrigger = $true
                        $reason = "RSSI sustained below ${threshold}dBm for $([int]$sustained)s"
                    }
                } else {
                    if ($script:App.RssiBelowSince) {
                        Write-Log DEBUG 'Poll' "RSSI recovered, clearing sustain timer"
                        $script:App.RssiBelowSince = $null
                    }
                }
            }
        }

        # --- Idle gate: only lock if the user has actually stopped using the
        #     machine. BT presence detection on classic devices is unreliable
        #     enough that we'd rather let the screensaver / OS lock handle the
        #     case where you walk away with a quiet keyboard. ---
        if ($shouldTrigger) {
            $requireIdle = [int]$script:App.Config.lock.requireIdleSeconds
            if ($requireIdle -gt 0) {
                $idleSec = Get-IdleSeconds
                if ($idleSec -ne $null -and $idleSec -lt $requireIdle) {
                    Write-Log INFO 'Poll' ("Lock suppressed by user activity (idle={0:N0}s < {1}s). Would-be reason: {2}" -f $idleSec, $requireIdle, $reason)
                    $shouldTrigger = $false
                    # Don't reset DisconnectedSince — if BT stays away, the moment
                    # user goes idle we want to lock immediately, not re-debounce.
                }
            }
        }

        # --- Grace period: suppress lock right after start/unlock so the BT
        #     stack has time to converge after a session boundary. ---
        if ($shouldTrigger -and $script:App.GraceUntil -and (Get-Date) -lt $script:App.GraceUntil) {
            $remain = [int](($script:App.GraceUntil - (Get-Date)).TotalSeconds)
            Write-Log INFO 'Poll' "Lock suppressed by grace period (${remain}s left). Would-be reason: $reason"
            $shouldTrigger = $false
        } elseif ($script:App.GraceUntil -and (Get-Date) -ge $script:App.GraceUntil) {
            Write-Log DEBUG 'Poll' "Grace period expired"
            $script:App.GraceUntil = $null
        }

        if ($shouldTrigger) {
            Start-Countdown -Reason $reason
        } else {
            if ($script:App.State -ne 'Monitoring') {
                Set-AppState 'Monitoring'
            }
        }
        # Force garbage collection to prevent WinRT handle/memory buildup over long runtimes
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    } catch {
        Write-Log ERROR 'Poll' "Poll tick failed: $($_.Exception.Message)"
        Set-AppState 'Error'
    } finally {
        $script:PollTickActive = $false
    }
}

function Start-Monitoring {
    if (-not $script:App.Config.device.id) {
        throw "No target device in config; run first-run setup first"
    }

    $devKind = if ($script:App.Config.device.kind) { $script:App.Config.device.kind } else { 'auto' }
    $btAddr  = $null
    if ($script:App.Config.device.bluetoothAddress) {
        try { $btAddr = [uint64]$script:App.Config.device.bluetoothAddress } catch { }
    }
    $useRssi = [bool]$script:App.Config.monitor.useRssi

    Initialize-BluetoothMonitor `
        -DeviceId $script:App.Config.device.id `
        -DeviceKind $devKind `
        -BluetoothAddress $btAddr `
        -UseRssi $useRssi `
        -RssiAdvertisementTtl ([int]$script:App.Config.monitor.rssiAdvertisementTtl) | Out-Null

    $pollInterval = [int]$script:App.Config.monitor.pollIntervalSeconds
    if ($pollInterval -lt 1) { $pollInterval = 1 }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $pollInterval * 1000
    $timer.Add_Tick({ Invoke-PollTick })
    $script:App.PollTimer = $timer
    $timer.Start()

    Write-Log INFO 'App' ("Monitoring started. Device='{0}' poll={1}s delay={2}s useRssi={3}" -f `
        $script:App.Config.device.name, $pollInterval, [int]$script:App.Config.lock.delaySeconds, $useRssi)

    Set-AppState 'Monitoring'
    # Arm grace period BEFORE the first immediate tick so a stale "disconnected"
    # snapshot doesn't bypass debouncing right at startup.
    Set-GracePeriod -Reason 'monitoring started'
    # Run one immediate tick so we don't wait the full interval to settle
    Invoke-PollTick
}

function Stop-Monitoring {
    if ($script:App.PollTimer) {
        $script:App.PollTimer.Stop()
        $script:App.PollTimer.Dispose()
        $script:App.PollTimer = $null
    }
    if ($script:App.CountdownTimer) {
        $script:App.CountdownTimer.Stop()
        $script:App.CountdownTimer.Dispose()
        $script:App.CountdownTimer = $null
    }
    $script:App.DisconnectedSince = $null
    $script:App.RssiBelowSince    = $null
    $script:App.GraceUntil        = $null
    $script:App.ProbeFailureCount = 0
    $script:App.ConnectedSince    = $null
    Stop-BluetoothMonitor
}

# ============================================================================
# Bootstrapping
# ============================================================================

function Open-Path {
    param([string] $Path)
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Path`""
    }
}

function Get-AutoStartRegistered {
    $RegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $ValueName = 'ProximityLock'
    $val = (Get-ItemProperty -LiteralPath $RegPath -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
    return [bool]$val
}

function Set-AutoStartRegistered {
    param([bool] $Enabled)
    $RegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $ValueName = 'ProximityLock'
    if ($Enabled) {
        $Launcher  = Join-Path $script:App.AppRoot 'Start-ProximityLock.vbs'
        $cmd = "wscript.exe `"$Launcher`""
        if (-not (Test-Path -LiteralPath $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $RegPath -Name $ValueName -Value $cmd
        Write-Log INFO 'App' "Registered auto-start: $cmd"
    } else {
        if (Get-ItemProperty -LiteralPath $RegPath -Name $ValueName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -LiteralPath $RegPath -Name $ValueName
            Write-Log INFO 'App' "Unregistered auto-start"
        }
    }
}

function Initialize-App {
    # 1. Load or create config
    if (-not (Test-ConfigExists -Path $ConfigPath) -or $ResetDevice) {
        if ($ResetDevice -and (Test-ConfigExists -Path $ConfigPath)) {
            Write-Host "Resetting device selection..." -ForegroundColor Yellow
        }
        $cfg = Invoke-FirstRunSetup -ConfigPath $ConfigPath
    } else {
        $cfg = Read-Config -Path $ConfigPath
        $cfg = Merge-ConfigDefaults -Config $cfg
        if (-not $cfg.device.id) {
            Write-Host "Config has no device selected; running setup..." -ForegroundColor Yellow
            $cfg = Invoke-FirstRunSetup -ConfigPath $ConfigPath
        }
    }
    $script:App.Config = $cfg

    # 2. Initialize logger
    $logDir = Resolve-PathRelative -BasePath $AppRoot -InputPath $cfg.logging.directory
    $minLvl = if ($DebugLog) { 'DEBUG' } else { $cfg.logging.level }
    Initialize-Logger -Directory $logDir -MinLevel $minLvl `
        -MaxBytes ([int64]$cfg.logging.maxBytes) `
        -KeepFiles ([int]$cfg.logging.keepFiles) `
        -EchoToConsole ([bool]$cfg.logging.echoToConsole)

    Write-Log INFO 'App' "==== Proximity Lock starting (root=$AppRoot, config=$ConfigPath) ===="
    Write-Log INFO 'App' ("Target device: {0} ({1})" -f $cfg.device.name, $cfg.device.kind)

    # 3. Tray
    if (-not $NoTray) {
        Initialize-Tray `
            -OnToggleEnabled { OnMenu-ToggleEnabled } `
            -OnLockNow       { OnMenu-LockNow } `
            -OnToggleAutoStart { param($checked) OnMenu-ToggleAutoStart $checked } `
            -OnOpenLogs      { OnMenu-OpenLogs } `
            -OnOpenConfig    { OnMenu-OpenConfig } `
            -OnSelectDevice  { OnMenu-SelectDevice } `
            -OnExit          { OnMenu-Exit } | Out-Null
        Update-TrayToggleLabel -Enabled $true
        Update-TrayStatus -State 'Idle' -DeviceName $cfg.device.name
        Update-TrayAutoStartCheck -Checked (Get-AutoStartRegistered)
    }

    # 4. Session events
    Register-SessionEvents `
        -OnLock   { Write-Log INFO 'App' "Workstation locked (by us or otherwise)"; Set-AppState 'Locked' } `
        -OnUnlock {
            Write-Log INFO 'App' "Workstation unlocked"
            Invoke-UnlockHook
            # Reset sustain timers so a stale "disconnected" reading from before
            # the lock doesn't immediately re-trigger after unlock.
            $script:App.DisconnectedSince = $null
            $script:App.RssiBelowSince    = $null
            $script:App.ProbeFailureCount = 0
            $script:App.ConnectedSince    = $null
            $script:App.ScreenWakeSent    = $false
            Set-GracePeriod -Reason 'workstation unlocked'
            # Resume monitoring after unlock
            if ($script:App.Enabled) {
                Set-AppState 'Monitoring'
                Invoke-PollTick
            }
        }

    # 5. Start monitor
    if ([bool]$cfg.autoStart.startEnabled) {
        Start-Monitoring
    } else {
        Set-AppState 'Disabled'
        $script:App.Enabled = $false
        if (-not $NoTray) { Update-TrayToggleLabel -Enabled $false }
    }
}

# --- Menu handlers ---
function OnMenu-ToggleAutoStart {
    param([bool] $Checked)
    try {
        Set-AutoStartRegistered -Enabled $Checked
    } catch {
        Write-Log ERROR 'App' "Toggle auto-start failed: $($_.Exception.Message)"
    }
}

function OnMenu-ToggleEnabled {
    if ($script:App.Enabled) {
        Write-Log INFO 'App' "User disabled monitoring"
        $script:App.Enabled = $false
        Stop-Monitoring
        Set-AppState 'Disabled'
        if (-not $NoTray) {
            Update-TrayToggleLabel -Enabled $false
            Show-TrayBalloon -Title (Get-LocaleString 'ProximityLock') -Message (Get-LocaleString 'MonitoringDisabled') -Kind Info
        }
    } else {
        Write-Log INFO 'App' "User enabled monitoring"
        $script:App.Enabled = $true
        Start-Monitoring
        if (-not $NoTray) {
            Update-TrayToggleLabel -Enabled $true
            Show-TrayBalloon -Title (Get-LocaleString 'ProximityLock') -Message (Get-LocaleString 'MonitoringEnabled') -Kind Info
        }
    }
}
function OnMenu-LockNow {
    Write-Log INFO 'App' "User invoked Lock now"
    [void](Invoke-WorkstationLock)
}
function OnMenu-OpenLogs {
    Open-Path (Get-LogDirectory)
}
function OnMenu-OpenConfig {
    if (Test-Path -LiteralPath $ConfigPath) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$ConfigPath`""
    }
}
function OnMenu-SelectDevice {
    try {
        $devs = @(Get-PairedBluetoothDevices)
        if ($devs.Count -eq 0) {
            Show-TrayBalloon -Title (Get-LocaleString 'ProximityLock') -Message (Get-LocaleString 'NoPairedDevices') -Kind Warning
            return
        }
        $chosen = Select-DeviceForm -Devices $devs
        if (-not $chosen) { return }
        Write-Log INFO 'App' "User changed device: $($chosen.Name) ($($chosen.Kind))"
        Stop-Monitoring
        $script:App.Config.device.id               = $chosen.Id
        $script:App.Config.device.name             = $chosen.Name
        $script:App.Config.device.kind             = $chosen.Kind
        $script:App.Config.device.bluetoothAddress = if ($chosen.BluetoothAddress) { [string]$chosen.BluetoothAddress } else { $null }
        Write-Config -Path $ConfigPath -Config $script:App.Config
        if ($script:App.Enabled) { Start-Monitoring }
        Show-TrayBalloon -Title (Get-LocaleString 'ProximityLock') -Message (Get-LocaleString 'NowTracking' $chosen.Name) -Kind Info
    } catch {
        Write-Log ERROR 'App' "Select device failed: $($_.Exception.Message)"
    }
}
function OnMenu-Exit {
    Write-Log INFO 'App' "User invoked Exit"
    $script:App.ExitRequested = $true
    [System.Windows.Forms.Application]::Exit()
}

# ============================================================================
# Main
# ============================================================================

if (-not (Test-AndAcquireSingleInstance)) {
    $msg = Get-LocaleString 'AlreadyRunning'
    Write-Host $msg -ForegroundColor Yellow
    if (-not $NoTray) {
        try { [System.Windows.Forms.MessageBox]::Show($msg, (Get-LocaleString 'ProximityLock'), 'OK', 'Information') | Out-Null } catch { }
    }
    exit 0
}

try {
    Initialize-App
} catch {
    $msg = "Startup failed: $($_.Exception.Message)"
    try { Write-Log ERROR 'App' $msg } catch { }
    Write-Host $msg -ForegroundColor Red
    if (-not $NoTray) {
        try { [System.Windows.Forms.MessageBox]::Show($msg, 'Proximity Lock', 'OK', 'Error') | Out-Null } catch { }
    }
    exit 1
}

try {
    if (-not $NoTray) {
        # Run the message loop (blocks until Application.Exit is called)
        [System.Windows.Forms.Application]::Run()
    } else {
        # Headless: still need a message pump so SystemEvents and timers work
        [System.Windows.Forms.Application]::Run()
    }
} finally {
    Write-Log INFO 'App' "Shutting down"
    try { Stop-Monitoring } catch { }
    try { Unregister-SessionEvents } catch { }
    try { Clear-HookJobs } catch { }
    if (-not $NoTray) {
        try { Dispose-Tray } catch { }
    }
    if ($script:InstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
        try { $script:InstanceMutex.Dispose() } catch { }
        $script:InstanceMutex = $null
    }
    Write-Log INFO 'App' "==== Stopped ===="
}

