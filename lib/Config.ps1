# Config.ps1 -- JSON config load/save

$script:DefaultConfig = [ordered]@{
    version          = 1
    device           = [ordered]@{
        id               = $null   # DeviceInformation.Id
        name             = $null   # Display name
        kind             = 'auto'  # auto | classic | le
        bluetoothAddress = $null   # ulong, LE only
    }
    monitor          = [ordered]@{
        pollIntervalSeconds        = 3
        useRssi                    = $false
        rssiThresholdDbm           = -85
        rssiSustainSeconds         = 15
        rssiAdvertisementTtl       = 30
        # Classic BT ConnectionStatus updates lazily, so require N consecutive
        # seconds of "disconnected" before treating it as a real disconnect.
        disconnectedSustainSeconds = 25
        # For classic devices, run an SDP query to wake the BT stack and
        # re-read connection status. 0 = probe on every disconnected tick.
        activeProbeEnabled         = $true
        activeProbeAfterSeconds    = 0
    }
    lock             = [ordered]@{
        delaySeconds          = 10
        cancelOnReconnect     = $true
        # Suppress lock for N seconds after monitoring starts or workstation
        # unlocks, giving the BT stack time to converge. Set to 0 to disable.
        gracePeriodSeconds    = 30
        # User must have been idle (no keyboard/mouse) at least this long
        # before we'll lock. Catches "BT thinks you left but you're typing".
        # Set to 0 to disable the idle gate entirely.
        requireIdleSeconds    = 30
    }
    hooks            = [ordered]@{
        onLock                = $null
        onUnlock              = $null
        timeoutSeconds        = 30
        runHidden             = $true
    }
    logging          = [ordered]@{
        directory             = 'logs'
        level                 = 'INFO'
        maxBytes              = 5242880
        keepFiles             = 10
        echoToConsole         = $false
    }
    autoStart        = [ordered]@{
        startEnabled          = $true
    }
}

function Get-DefaultConfig {
    $json = $script:DefaultConfig | ConvertTo-Json -Depth 10
    return $json | ConvertFrom-Json
}

function Test-ConfigExists {
    param([Parameter(Mandatory)][string] $Path)
    return Test-Path -LiteralPath $Path
}

function Read-Config {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return $raw | ConvertFrom-Json
    } catch {
        throw "Failed to parse config file ($Path): $($_.Exception.Message)"
    }
}

function Write-Config {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Config
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Resolve-PathRelative {
    param(
        [Parameter(Mandatory)][string] $BasePath,
        [string] $InputPath
    )
    if ([string]::IsNullOrWhiteSpace($InputPath)) { return $null }
    if ([System.IO.Path]::IsPathRooted($InputPath)) { return $InputPath }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($BasePath, $InputPath))
}

function Merge-ConfigDefaults {
    param([Parameter(Mandatory)] $Config)
    $def = Get-DefaultConfig
    foreach ($topProp in $def.PSObject.Properties) {
        if (-not $Config.PSObject.Properties[$topProp.Name]) {
            Add-Member -InputObject $Config -NotePropertyName $topProp.Name -NotePropertyValue $topProp.Value -Force
            continue
        }
        $defSection = $topProp.Value
        $userSection = $Config.($topProp.Name)
        if ($defSection -is [psobject] -and $userSection -is [psobject]) {
            foreach ($p in $defSection.PSObject.Properties) {
                if (-not $userSection.PSObject.Properties[$p.Name]) {
                    Add-Member -InputObject $userSection -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
                }
            }
        }
    }
    return $Config
}
