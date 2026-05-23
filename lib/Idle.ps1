# Idle.ps1 -- query "seconds since last keyboard/mouse activity"
# via user32!GetLastInputInfo (the same source Windows uses for screensaver
# timeout). Works under the locked screen too (returns large values then).

if (-not ([System.Management.Automation.PSTypeName]'ProximityLock.IdleNative').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ProximityLock {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }
    public static class IdleNative {
        [DllImport("user32.dll")]
        public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        [DllImport("kernel32.dll")]
        public static extern uint GetTickCount();
    }
}
"@
}

function Get-IdleSeconds {
    <#
        Returns seconds since the last user input (keyboard/mouse) on this
        session, or $null if the underlying API call fails. Uses uint32 tick
        wrap-around-safe subtraction.
    #>
    $lii = New-Object ProximityLock.LASTINPUTINFO
    $lii.cbSize = [uint32][System.Runtime.InteropServices.Marshal]::SizeOf($lii)
    if (-not [ProximityLock.IdleNative]::GetLastInputInfo([ref]$lii)) {
        return $null
    }
    $now  = [ProximityLock.IdleNative]::GetTickCount()
    # Unsigned subtraction handles tick wrap (every ~49.7 days)
    $diff = [uint32]($now - $lii.dwTime)
    return [double]$diff / 1000.0
}
