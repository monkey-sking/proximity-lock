# Install-Startup.ps1 -- register/unregister Proximity Lock for auto-start at user logon
#
# Usage:
#   .\Install-Startup.ps1 -Action Install
#   .\Install-Startup.ps1 -Action Uninstall
#   .\Install-Startup.ps1 -Action Status

[CmdletBinding()]
param(
    [ValidateSet('Install','Uninstall','Status')] [string] $Action = 'Status'
)

$AppRoot   = Split-Path -Parent $PSCommandPath
$Launcher  = Join-Path $AppRoot 'Start-ProximityLock.vbs'
$RegPath   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$ValueName = 'ProximityLock'

switch ($Action) {
    'Install' {
        if (-not (Test-Path -LiteralPath $Launcher)) {
            throw "Launcher not found: $Launcher"
        }
        $cmd = "wscript.exe `"$Launcher`""
        if (-not (Test-Path -LiteralPath $RegPath)) {
            New-Item -Path $RegPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $RegPath -Name $ValueName -Value $cmd
        Write-Host "Installed auto-start:" -ForegroundColor Green
        Write-Host "  $RegPath\$ValueName = $cmd"
    }
    'Uninstall' {
        if (Get-ItemProperty -LiteralPath $RegPath -Name $ValueName -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -LiteralPath $RegPath -Name $ValueName
            Write-Host "Removed auto-start entry." -ForegroundColor Yellow
        } else {
            Write-Host "Auto-start entry not present; nothing to do."
        }
    }
    'Status' {
        $val = (Get-ItemProperty -LiteralPath $RegPath -Name $ValueName -ErrorAction SilentlyContinue).$ValueName
        if ($val) {
            Write-Host "Auto-start is INSTALLED:" -ForegroundColor Green
            Write-Host "  $val"
        } else {
            Write-Host "Auto-start is NOT installed." -ForegroundColor Yellow
        }
    }
}
