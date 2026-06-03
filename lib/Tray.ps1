# Tray.ps1 -- System tray (NotifyIcon) with menu and status updates

Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
Add-Type -AssemblyName System.Drawing      -ErrorAction Stop

$script:Tray = $null

function New-TrayIconImage {
    <#
        Draw a 16x16 icon at runtime; color reflects the state:
          green  = monitoring (connected/ok)
          yellow = countdown / warning
          red    = disconnected / inactive / disabled
    #>
    param([ValidateSet('Green','Yellow','Red','Gray')] [string] $Color)

    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = switch ($Color) {
        'Green'  { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 30, 200, 90))  }
        'Yellow' { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 240, 190, 50)) }
        'Red'    { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 220, 60, 60))  }
        'Gray'   { New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 150, 150))}
    }
    $g.FillEllipse($brush, 4, 4, 24, 24)
    $g.DrawEllipse([System.Drawing.Pens]::Black, 4, 4, 24, 24)

    # Draw a small "B" for Bluetooth
    $font = New-Object System.Drawing.Font 'Segoe UI', 12, ([System.Drawing.FontStyle]::Bold)
    $sf   = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString('B', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 4, 4, 24, 24), $sf)

    $g.Dispose()
    $font.Dispose()
    $brush.Dispose()

    $hicon = $bmp.GetHicon()
    $icon  = [System.Drawing.Icon]::FromHandle($hicon)
    return $icon
}

function Initialize-Tray {
    <#
        Creates the NotifyIcon. Returns an object with menu items to update at runtime.
        Callbacks (script blocks):
          -OnToggleEnabled     called when user clicks Enable/Disable
          -OnLockNow           called when user clicks Lock now
          -OnOpenLogs          called when user clicks Open logs
          -OnOpenConfig        called when user clicks Open config
          -OnSelectDevice      called when user clicks Select device...
          -OnExit              called when user clicks Exit
    #>
    param(
        [scriptblock] $OnToggleEnabled,
        [scriptblock] $OnLockNow,
        [scriptblock] $OnOpenLogs,
        [scriptblock] $OnOpenConfig,
        [scriptblock] $OnSelectDevice,
        [scriptblock] $OnExit
    )

    $notify = New-Object System.Windows.Forms.NotifyIcon
    $notify.Icon    = New-TrayIconImage -Color 'Gray'
    $notify.Visible = $true
    $notify.Text    = 'Proximity Lock'

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $miStatus = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'StatusStarting')
    $miStatus.Enabled = $false

    $miDevice = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'DeviceNone')
    $miDevice.Enabled = $false

    $miSep1   = New-Object System.Windows.Forms.ToolStripSeparator

    $miToggle = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'DisableMonitoring')
    if ($OnToggleEnabled) { $miToggle.Add_Click({ & $OnToggleEnabled }.GetNewClosure()) }

    $miLock   = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'LockNow')
    if ($OnLockNow) { $miLock.Add_Click({ & $OnLockNow }.GetNewClosure()) }

    $miSep2   = New-Object System.Windows.Forms.ToolStripSeparator

    $miSelect = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'SelectDeviceMenu')
    if ($OnSelectDevice) { $miSelect.Add_Click({ & $OnSelectDevice }.GetNewClosure()) }

    $miLogs   = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'OpenLogsFolder')
    if ($OnOpenLogs) { $miLogs.Add_Click({ & $OnOpenLogs }.GetNewClosure()) }

    $miCfg    = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'OpenConfigFile')
    if ($OnOpenConfig) { $miCfg.Add_Click({ & $OnOpenConfig }.GetNewClosure()) }

    $miSep3   = New-Object System.Windows.Forms.ToolStripSeparator

    $miExit   = New-Object System.Windows.Forms.ToolStripMenuItem (Get-LocaleString 'Exit')
    if ($OnExit) { $miExit.Add_Click({ & $OnExit }.GetNewClosure()) }

    [void]$menu.Items.AddRange(@($miStatus, $miDevice, $miSep1, $miToggle, $miLock, $miSep2, $miSelect, $miLogs, $miCfg, $miSep3, $miExit))
    $notify.ContextMenuStrip = $menu

    $script:Tray = [pscustomobject]@{
        Notify     = $notify
        Menu       = $menu
        StatusItem = $miStatus
        DeviceItem = $miDevice
        ToggleItem = $miToggle
    }
    return $script:Tray
}

function Update-TrayStatus {
    param(
        [Parameter(Mandatory)] [ValidateSet('Idle','Monitoring','Countdown','Locked','Disabled','Error')] [string] $State,
        [string] $DeviceName,
        [string] $ExtraText
    )
    if (-not $script:Tray) { return }

    $color = switch ($State) {
        'Idle'       { 'Gray'   }
        'Monitoring' { 'Green'  }
        'Countdown'  { 'Yellow' }
        'Locked'     { 'Gray'   }
        'Disabled'   { 'Red'    }
        'Error'      { 'Red'    }
    }

    $oldIcon = $script:Tray.Notify.Icon
    $script:Tray.Notify.Icon = New-TrayIconImage -Color $color
    try { if ($oldIcon) { $oldIcon.Dispose() } } catch { }

    $label = "$((Get-LocaleString 'Status')): $State"
    if ($ExtraText) { $label += " ($ExtraText)" }
    $script:Tray.StatusItem.Text = $label

    if ($DeviceName) {
        $script:Tray.DeviceItem.Text = "$((Get-LocaleString 'Device')): $DeviceName"
    }

    $tip = $label
    if ($DeviceName) { $tip = "$((Get-LocaleString 'ProximityLock')) - $DeviceName`n$label" }
    # NotifyIcon.Text has 63-char limit historically; modern Windows allows 127
    if ($tip.Length -gt 127) { $tip = $tip.Substring(0, 127) }
    $script:Tray.Notify.Text = $tip
}

function Update-TrayToggleLabel {
    param([Parameter(Mandatory)] [bool] $Enabled)
    if (-not $script:Tray) { return }
    $script:Tray.ToggleItem.Text = if ($Enabled) { Get-LocaleString 'DisableMonitoring' } else { Get-LocaleString 'EnableMonitoring' }
}

function Show-TrayBalloon {
    param(
        [Parameter(Mandatory)] [string] $Title,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('Info','Warning','Error')] [string] $Kind = 'Info',
        [int] $TimeoutMs = 3000
    )
    if (-not $script:Tray) { return }
    $icon = switch ($Kind) {
        'Info'    { [System.Windows.Forms.ToolTipIcon]::Info }
        'Warning' { [System.Windows.Forms.ToolTipIcon]::Warning }
        'Error'   { [System.Windows.Forms.ToolTipIcon]::Error }
    }
    $script:Tray.Notify.ShowBalloonTip($TimeoutMs, $Title, $Message, $icon)
}

function Dispose-Tray {
    if (-not $script:Tray) { return }
    try { $script:Tray.Notify.Visible = $false } catch { }
    try { $script:Tray.Notify.Dispose() } catch { }
    $script:Tray = $null
}
