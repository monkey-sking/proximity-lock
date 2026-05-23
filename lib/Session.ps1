# Session.ps1 -- listen to Windows session lock/unlock events
# Uses Microsoft.Win32.SystemEvents.SessionSwitch which requires a message pump.
# Our main loop runs Application.Run() so the pump is available.

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System -ErrorAction Stop      # for Microsoft.Win32.SystemEvents

$script:SessionListener = $null

function Register-SessionEvents {
    <#
        Wires SessionSwitch event.
        Params:
          -OnLock     scriptblock to run when session is locked
          -OnUnlock   scriptblock to run when session is unlocked
    #>
    param(
        [scriptblock] $OnLock,
        [scriptblock] $OnUnlock
    )

    if ($script:SessionListener) {
        Write-Log WARN 'Session' "Session events already registered; replacing"
        Unregister-SessionEvents
    }

    # Use a wrapper object to keep the delegate alive (otherwise GC can collect it)
    $listener = New-Object psobject -Property @{
        OnLock   = $OnLock
        OnUnlock = $OnUnlock
        Delegate = $null
    }

    $delegate = [Microsoft.Win32.SessionSwitchEventHandler] {
        param($s, $e)
        try {
            switch ($e.Reason) {
                ([Microsoft.Win32.SessionSwitchReason]::SessionLock) {
                    Write-Log INFO 'Session' "SessionLock detected"
                    if ($script:SessionListener.OnLock) {
                        & $script:SessionListener.OnLock
                    }
                }
                ([Microsoft.Win32.SessionSwitchReason]::SessionUnlock) {
                    Write-Log INFO 'Session' "SessionUnlock detected"
                    if ($script:SessionListener.OnUnlock) {
                        & $script:SessionListener.OnUnlock
                    }
                }
            }
        } catch {
            Write-Log ERROR 'Session' "Session event handler failed: $($_.Exception.Message)"
        }
    }

    $listener.Delegate = $delegate
    $script:SessionListener = $listener
    [Microsoft.Win32.SystemEvents]::add_SessionSwitch($delegate)
    Write-Log INFO 'Session' "Session lock/unlock listener registered"
}

function Unregister-SessionEvents {
    if (-not $script:SessionListener) { return }
    try {
        [Microsoft.Win32.SystemEvents]::remove_SessionSwitch($script:SessionListener.Delegate)
    } catch { }
    $script:SessionListener = $null
    Write-Log INFO 'Session' "Session lock/unlock listener unregistered"
}
