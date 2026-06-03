# Bluetooth.ps1 -- Enumerate paired devices, monitor connection + optional RSSI

# Requires: WinRT.ps1 and Logger.ps1 dot-sourced beforehand

# State held by the monitor instance
$script:BtMonitor = $null

function Get-PairedBluetoothDevices {
    <#
        Enumerate paired Bluetooth devices (classic + LE).
        Returns array of objects:
          @{ Id; Name; Kind = 'classic'|'le'; BluetoothAddress (LE only) }
    #>
    $results = @()
    try {
        $sel = [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromPairingState($true)
        $col = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
        foreach ($d in $col) {
            $results += [pscustomobject]@{
                Id               = $d.Id
                Name             = $d.Name
                Kind             = 'classic'
                BluetoothAddress = $null
            }
        }
    } catch {
        Write-Log WARN 'Bluetooth' "Enumerate classic paired failed: $($_.Exception.Message)"
    }

    try {
        $selLe = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromPairingState($true)
        $colLe = Await ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($selLe)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
        foreach ($d in $colLe) {
            # Try to resolve BluetoothAddress (for RSSI matching). Best-effort.
            $addr = $null
            try {
                $le = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($d.Id)) ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 5000
                if ($le) { $addr = $le.BluetoothAddress }
            } catch { }
            $results += [pscustomobject]@{
                Id               = $d.Id
                Name             = $d.Name
                Kind             = 'le'
                BluetoothAddress = $addr
            }
        }
    } catch {
        Write-Log WARN 'Bluetooth' "Enumerate LE paired failed: $($_.Exception.Message)"
    }

    return $results
}

function Initialize-BluetoothMonitor {
    <#
        Create monitor state. Resolves the target device and prepares for status polling
        + optional advertisement-based RSSI tracking.

        Params:
          -DeviceId           DeviceInformation.Id of target
          -DeviceKind         'classic' | 'le' | 'auto'
          -BluetoothAddress   ulong (LE only, for RSSI watcher filter); if missing we will try to resolve
          -UseRssi            $true to enable LE advertisement watcher
          -RssiAdvertisementTtl   seconds; if no advert seen within this, RSSI is considered "lost"
    #>
    param(
        [Parameter(Mandatory)] [string] $DeviceId,
        [string] $DeviceKind = 'auto',
        [Nullable[uint64]] $BluetoothAddress = $null,
        [bool] $UseRssi = $false,
        [int] $RssiAdvertisementTtl = 30
    )

    $state = [pscustomobject]@{
        DeviceId             = $DeviceId
        DeviceKind           = $DeviceKind   # may get refined below
        BluetoothAddress     = $BluetoothAddress
        Device               = $null         # WinRT BluetoothDevice or BluetoothLEDevice
        UseRssi              = $UseRssi
        RssiAdvertisementTtl = $RssiAdvertisementTtl
        Watcher              = $null
        LastRssi             = $null
        LastRssiAt           = $null
        LastConnected        = $null
        LastConnectionAt     = (Get-Date)
        SubscriptionIds      = @()
    }

    # Try classic first if kind is auto or classic
    if ($DeviceKind -in @('auto','classic')) {
        try {
            $dev = Await ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($DeviceId)) ([Windows.Devices.Bluetooth.BluetoothDevice]) 5000
            if ($dev) {
                $state.Device     = $dev
                $state.DeviceKind = 'classic'
                Write-Log INFO 'Bluetooth' "Bound classic device: $($dev.Name) [$($dev.DeviceId)]"
            }
        } catch {
            Write-Log DEBUG 'Bluetooth' "Not a classic device: $($_.Exception.Message)"
        }
    }

    if (-not $state.Device -and $DeviceKind -in @('auto','le')) {
        try {
            $dev = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($DeviceId)) ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 5000
            if ($dev) {
                $state.Device           = $dev
                $state.DeviceKind       = 'le'
                $state.BluetoothAddress = $dev.BluetoothAddress
                Write-Log INFO 'Bluetooth' "Bound LE device: $($dev.Name) [addr=$($dev.BluetoothAddress)]"
            }
        } catch {
            Write-Log DEBUG 'Bluetooth' "Not an LE device: $($_.Exception.Message)"
        }
    }

    if (-not $state.Device) {
        throw "Failed to bind target Bluetooth device: $DeviceId"
    }

    # Start LE advertisement watcher if requested and we have an address
    if ($UseRssi) {
        if ($state.DeviceKind -ne 'le' -or -not $state.BluetoothAddress) {
            Write-Log WARN 'Bluetooth' "useRssi is enabled but target is not LE / has no address; RSSI tracking disabled"
            $state.UseRssi = $false
        } else {
            Start-RssiWatcher -State $state
        }
    }

    $script:BtMonitor = $state
    return $state
}

function Start-RssiWatcher {
    param([Parameter(Mandatory)] $State)

    $watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
    $watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active

    # Use a synchronized hashtable to safely receive data from event runspace
    $sync = [hashtable]::Synchronized(@{
        LastRssi   = $null
        LastRssiAt = $null
        TargetAddr = [uint64]$State.BluetoothAddress
    })
    $State | Add-Member -NotePropertyName _RssiSync -NotePropertyValue $sync -Force

    $sub = Register-ObjectEvent -InputObject $watcher -EventName Received -MessageData $sync -Action {
        $args0 = $EventArgs
        $sync  = $Event.MessageData
        if ($args0.BluetoothAddress -eq $sync.TargetAddr) {
            $sync.LastRssi   = [int]$args0.RawSignalStrengthInDBm
            $sync.LastRssiAt = Get-Date
        }
    }

    $State.Watcher         = $watcher
    $State.SubscriptionIds = @($sub.Id)
    $watcher.Start()
    Write-Log INFO 'Bluetooth' "RSSI advertisement watcher started (target addr=$($State.BluetoothAddress))"
}

function Stop-BluetoothMonitor {
    if (-not $script:BtMonitor) { return }
    $s = $script:BtMonitor
    try {
        if ($s.Watcher) { $s.Watcher.Stop() }
    } catch { }
    foreach ($id in $s.SubscriptionIds) {
        try { Unregister-Event -SubscriptionId $id -ErrorAction SilentlyContinue } catch { }
    }
    try {
        if ($s.Device -and $s.Device.PSObject.Methods['Dispose']) { $s.Device.Dispose() }
    } catch { }
    $script:BtMonitor = $null
    Write-Log INFO 'Bluetooth' "Monitor stopped"
}

function Invoke-ClassicActiveProbe {
    <#
        Force the Windows BT stack to talk to the classic device by issuing an
        SDP query (GetRfcommServicesAsync with Uncached). This makes
        ConnectionStatus reflect reality — without it, classic BT
        ConnectionStatus is almost always 'Disconnected' even when the device
        is in range.

        Returns $true if the device is reachable, $false otherwise.
        Bounded by a short timeout so the caller (a Timer.Tick) doesn't stall.
    #>
    param(
        [Parameter(Mandatory)] $Device,
        [int] $TimeoutMs = 6000
    )
    try {
        $res = Await `
            ($Device.GetRfcommServicesAsync([Windows.Devices.Bluetooth.BluetoothCacheMode]::Uncached)) `
            ([Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult]) $TimeoutMs
        if ($res -and $res.Error -eq [Windows.Devices.Bluetooth.BluetoothError]::Success -and $res.Services -and $res.Services.Count -gt 0) {
            return $true
        }
        $svcCount = if ($res -and $res.Services) { $res.Services.Count } else { 0 }
        $errStr = if ($res) { "$($res.Error.ToString()) (services=$svcCount)" } else { "null result" }
        Write-Log DEBUG 'Bluetooth' "Active probe returned: $errStr"
        return $false
    } catch {
        Write-Log DEBUG 'Bluetooth' "Active probe failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-BluetoothStatusSnapshot {
    <#
        Returns a snapshot:
          @{
            Connected   = $true/$false       # current Bluetooth connection state
            Rssi        = int or $null       # last seen RSSI (LE only)
            RssiAgeSec  = double or $null    # how stale the RSSI is
            DeviceName  = string
            DeviceKind  = 'classic'|'le'
            ProbeUsed   = $true/$false       # whether an active SDP probe was used
          }

        -ActiveProbe : when $true and the device is classic, run an SDP query
                      to force ConnectionStatus refresh. Adds ~50ms-2s latency
                      but is the only reliable way for classic devices.
    #>
    param([bool] $ActiveProbe = $false)

    if (-not $script:BtMonitor) {
        throw "Bluetooth monitor not initialized"
    }
    $s = $script:BtMonitor

    # Re-resolve device to get fresh ConnectionStatus (WinRT updates the cached object lazily)
    $connected = $false
    $probeUsed = $false
    try {
        if ($s.DeviceKind -eq 'classic') {
            $fresh = Await ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($s.DeviceId)) ([Windows.Devices.Bluetooth.BluetoothDevice]) 5000
            if ($fresh) {
                $connected = ($fresh.ConnectionStatus -eq [Windows.Devices.Bluetooth.BluetoothConnectionStatus]::Connected)
                if ($fresh -ne $s.Device -and $s.Device.PSObject.Methods['Dispose']) {
                    try { $s.Device.Dispose() } catch { }
                }
                $s.Device = $fresh
            }

            # Classic ConnectionStatus is unreliable when idle; if caller asked
            # for an active probe AND cached state is disconnected, force-talk
            # to the device and re-read.
            if ($ActiveProbe -and -not $connected -and $s.Device) {
                $probeUsed = $true
                $reachable = Invoke-ClassicActiveProbe -Device $s.Device
                if ($reachable) {
                    $fresh2 = Await ([Windows.Devices.Bluetooth.BluetoothDevice]::FromIdAsync($s.DeviceId)) ([Windows.Devices.Bluetooth.BluetoothDevice]) 3000
                    if ($fresh2) {
                        $connected = ($fresh2.ConnectionStatus -eq [Windows.Devices.Bluetooth.BluetoothConnectionStatus]::Connected)
                        if ($fresh2 -ne $s.Device -and $s.Device.PSObject.Methods['Dispose']) {
                            try { $s.Device.Dispose() } catch { }
                        }
                        $s.Device = $fresh2
                    }
                    if (-not $connected) {
                        # SDP succeeded but status still says disconnected: the
                        # successful SDP itself is evidence of presence, trust it.
                        $connected = $true
                    }
                    Write-Log DEBUG 'Bluetooth' "Active probe: reachable, connected=$connected"
                } else {
                    Write-Log DEBUG 'Bluetooth' "Active probe: device not reachable"
                }
            }
        } else {
            $fresh = Await ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($s.DeviceId)) ([Windows.Devices.Bluetooth.BluetoothLEDevice]) 5000
            if ($fresh) {
                $connected = ($fresh.ConnectionStatus -eq [Windows.Devices.Bluetooth.BluetoothConnectionStatus]::Connected)
                if ($fresh -ne $s.Device -and $s.Device.PSObject.Methods['Dispose']) {
                    try { $s.Device.Dispose() } catch { }
                }
                $s.Device = $fresh
            }
        }
    } catch {
        Write-Log WARN 'Bluetooth' "Status poll failed: $($_.Exception.Message)"
        # Conservative: if we cannot poll, treat as not connected
        $connected = $false
    }

    $rssi      = $null
    $rssiAge   = $null
    if ($s.UseRssi -and $s._RssiSync) {
        $rssi = $s._RssiSync.LastRssi
        if ($s._RssiSync.LastRssiAt) {
            $rssiAge = ((Get-Date) - $s._RssiSync.LastRssiAt).TotalSeconds
            if ($rssiAge -gt $s.RssiAdvertisementTtl) { $rssi = $null }
        }
    }

    return [pscustomobject]@{
        Connected  = [bool]$connected
        Rssi       = $rssi
        RssiAgeSec = $rssiAge
        DeviceName = $s.Device.Name
        DeviceKind = $s.DeviceKind
        ProbeUsed  = $probeUsed
    }
}
