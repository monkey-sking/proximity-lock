# Lock.ps1 -- LockWorkStation P/Invoke + hook script runner

# Requires: Logger.ps1 dot-sourced beforehand

if (-not ([System.Management.Automation.PSTypeName]'ProximityLock.Native').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ProximityLock {
    public static class Native {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool LockWorkStation();
    }
}
"@
}

function Invoke-WorkstationLock {
    [bool] $ok = [ProximityLock.Native]::LockWorkStation()
    if ($ok) {
        Write-Log INFO 'Lock' "LockWorkStation() invoked successfully"
    } else {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Write-Log ERROR 'Lock' "LockWorkStation() failed (Win32 error $err)"
    }
    return $ok
}

function Invoke-HookScript {
    <#
        Run a hook script (.bat / .cmd / .ps1 / .exe). Captures stdout/stderr, exit code,
        and enforces a timeout. Returns @{ ExitCode; TimedOut; StdOut; StdErr }.
    #>
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $HookName,   # for log tagging: 'OnLock' / 'OnUnlock'
        [int] $TimeoutSeconds = 30,
        [bool] $RunHidden = $true
    )

    if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
        Write-Log DEBUG 'Hook' "${HookName}: no script configured, skip"
        return $null
    }
    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        Write-Log ERROR 'Hook' "${HookName} script not found: $ScriptPath"
        return $null
    }

    $ext = [System.IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    if ($RunHidden) { $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden }
    $psi.WorkingDirectory       = [System.IO.Path]::GetDirectoryName($ScriptPath)

    switch ($ext) {
        '.bat' { $psi.FileName = $env:ComSpec; $psi.Arguments = "/c `"$ScriptPath`"" }
        '.cmd' { $psi.FileName = $env:ComSpec; $psi.Arguments = "/c `"$ScriptPath`"" }
        '.ps1' {
            $psi.FileName  = (Get-Process -Id $PID).Path  # current powershell.exe
            $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
        }
        '.exe' { $psi.FileName = $ScriptPath }
        default {
            Write-Log ERROR 'Hook' "${HookName}: unsupported script extension '$ext' for $ScriptPath"
            return $null
        }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # Async readers to avoid deadlock when stdout/stderr fill OS buffers
    $sbOut = New-Object System.Text.StringBuilder
    $sbErr = New-Object System.Text.StringBuilder
    $outHandler = {
        if ($EventArgs.Data -ne $null) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    }
    $errHandler = {
        if ($EventArgs.Data -ne $null) { [void]$Event.MessageData.AppendLine($EventArgs.Data) }
    }
    $subOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outHandler -MessageData $sbOut
    $subErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $errHandler -MessageData $sbErr

    $timedOut = $false
    $exitCode = $null

    try {
        $startedAt = Get-Date
        Write-Log INFO 'Hook' "$HookName starting: $ScriptPath (timeout=${TimeoutSeconds}s)"
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $proc.Kill() } catch { }
            Write-Log WARN 'Hook' "$HookName timed out after ${TimeoutSeconds}s, killed"
        } else {
            $exitCode = $proc.ExitCode
            $dur = ((Get-Date) - $startedAt).TotalMilliseconds
            $msg = "$HookName finished: exitCode=$exitCode duration=${dur}ms"
            if ($exitCode -eq 0) { Write-Log INFO 'Hook' $msg }
            else { Write-Log WARN 'Hook' $msg }
        }
    } catch {
        Write-Log ERROR 'Hook' "$HookName failed to execute: $($_.Exception.Message)"
    } finally {
        try { Unregister-Event -SubscriptionId $subOut.Id -ErrorAction SilentlyContinue } catch { }
        try { Unregister-Event -SubscriptionId $subErr.Id -ErrorAction SilentlyContinue } catch { }
        try { $proc.Dispose() } catch { }
    }

    $stdOut = $sbOut.ToString().TrimEnd()
    $stdErr = $sbErr.ToString().TrimEnd()
    if ($stdOut) {
        foreach ($l in $stdOut -split "`r?`n") { if ($l) { Write-Log DEBUG 'Hook' "$HookName stdout> $l" } }
    }
    if ($stdErr) {
        foreach ($l in $stdErr -split "`r?`n") { if ($l) { Write-Log WARN 'Hook' "$HookName stderr> $l" } }
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        StdOut   = $stdOut
        StdErr   = $stdErr
    }
}
