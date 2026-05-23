# Logger.ps1 -- Leveled logger, daily file + size-based rotation
# Levels: DEBUG < INFO < WARN < ERROR
# Usage: Initialize-Logger; Write-Log INFO Module "message"

$script:LogConfig = @{
    Directory     = $null
    BaseName      = 'proximity_lock'
    MinLevel      = 'INFO'
    MaxBytes      = 5MB
    KeepFiles     = 10
    CurrentFile   = $null
    CurrentDate   = $null
    LevelRank     = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3 }
    Mutex         = $null
    EchoToConsole = $true
}

function Initialize-Logger {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string] $BaseName = 'proximity_lock',
        [ValidateSet('DEBUG','INFO','WARN','ERROR')] [string] $MinLevel = 'INFO',
        [int] $MaxBytes = 5MB,
        [int] $KeepFiles = 10,
        [bool] $EchoToConsole = $true
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $script:LogConfig.Directory     = (Resolve-Path -LiteralPath $Directory).Path
    $script:LogConfig.BaseName      = $BaseName
    $script:LogConfig.MinLevel      = $MinLevel
    $script:LogConfig.MaxBytes      = $MaxBytes
    $script:LogConfig.KeepFiles     = $KeepFiles
    $script:LogConfig.EchoToConsole = $EchoToConsole
    $script:LogConfig.Mutex         = New-Object System.Threading.Mutex($false, "Global\ProximityLock_Logger_$BaseName")

    Update-LogFilePath
}

function Update-LogFilePath {
    $today = (Get-Date).ToString('yyyyMMdd')
    if ($script:LogConfig.CurrentDate -ne $today) {
        $script:LogConfig.CurrentDate = $today
        $script:LogConfig.CurrentFile = Join-Path $script:LogConfig.Directory ("{0}_{1}.log" -f $script:LogConfig.BaseName, $today)
    }
}

function Test-LogRotate {
    if (-not (Test-Path -LiteralPath $script:LogConfig.CurrentFile)) { return }
    $size = (Get-Item -LiteralPath $script:LogConfig.CurrentFile).Length
    if ($size -lt $script:LogConfig.MaxBytes) { return }

    $base = $script:LogConfig.CurrentFile
    $keep = $script:LogConfig.KeepFiles

    $oldest = "$base.$keep"
    if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force -ErrorAction SilentlyContinue }

    for ($i = $keep - 1; $i -ge 1; $i--) {
        $src = "$base.$i"
        $dst = "$base.$($i + 1)"
        if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue }
    }
    Move-Item -LiteralPath $base -Destination "$base.1" -Force -ErrorAction SilentlyContinue
}

function Write-Log {
    param(
        [Parameter(Mandatory, Position=0)] [ValidateSet('DEBUG','INFO','WARN','ERROR')] [string] $Level,
        [Parameter(Mandatory, Position=1)] [string] $Module,
        [Parameter(Mandatory, Position=2)] [string] $Message
    )

    if (-not $script:LogConfig.CurrentFile) {
        Write-Host "[unlogged] [$Level] [$Module] $Message"
        return
    }

    if ($script:LogConfig.LevelRank[$Level] -lt $script:LogConfig.LevelRank[$script:LogConfig.MinLevel]) {
        return
    }

    Update-LogFilePath

    $ts   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "$ts [$Level] [$Module] $Message"

    $acquired = $false
    try {
        $acquired = $script:LogConfig.Mutex.WaitOne(1000)
        Test-LogRotate
        # Append with UTF-8 (no BOM on append) using .NET to avoid PS 5.1 default encoding
        [System.IO.File]::AppendAllText($script:LogConfig.CurrentFile, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    } catch {
        Write-Host "[logger-error] $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        if ($acquired) { $script:LogConfig.Mutex.ReleaseMutex() }
    }

    if ($script:LogConfig.EchoToConsole) {
        $color = switch ($Level) {
            'DEBUG' { 'DarkGray' }
            'INFO'  { 'Gray' }
            'WARN'  { 'Yellow' }
            'ERROR' { 'Red' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

function Set-LogLevel {
    param([ValidateSet('DEBUG','INFO','WARN','ERROR')] [string] $Level)
    $script:LogConfig.MinLevel = $Level
}

function Get-LogDirectory { $script:LogConfig.Directory }
function Get-CurrentLogFile {
    Update-LogFilePath
    $script:LogConfig.CurrentFile
}
