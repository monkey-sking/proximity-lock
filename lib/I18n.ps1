# I18n.ps1 -- Simple localization module for Proximity Lock

$script:LocStrings = @{
    'en-US' = @{
        'SelectDeviceTitle'   = 'Proximity Lock - Select Device'
        'SelectDeviceLabel'   = 'Choose a paired Bluetooth device to use as your trusted key:'
        'BtnOk'               = 'OK'
        'BtnCancel'           = 'Cancel'
        'StatusStarting'      = 'Status: starting...'
        'DeviceNone'          = 'Device: (none)'
        'DisableMonitoring'   = 'Disable monitoring'
        'EnableMonitoring'    = 'Enable monitoring'
        'LockNow'             = 'Lock workstation now'
        'SelectDeviceMenu'    = 'Select target device...'
        'OpenLogsFolder'      = 'Open logs folder'
        'OpenConfigFile'      = 'Open config file'
        'Exit'                = 'Exit'
        'StartOnLogon'        = 'Start Proximity Lock on Logon'
        'Status'              = 'Status'
        'Device'              = 'Device'
        'ProximityLock'       = 'Proximity Lock'
        'MonitoringDisabled'  = 'Monitoring disabled.'
        'MonitoringEnabled'   = 'Monitoring enabled.'
        'NoPairedDevices'     = 'No paired devices found.'
        'NowTracking'         = 'Now tracking: {0}'
        'LockWarningTitle'    = 'Proximity Lock Warning'
        'LockWarningMessage'  = 'Device lost ({0}). Workstation will lock in {1} seconds.'
        'CliHeader'           = '=== Select target Bluetooth device ==='
        'CliVisible'          = 'Paired devices visible to this machine:'
        'CliPrompt'           = 'Enter number (1-{0})'
        'CliInvalid'          = 'Invalid input, try again.'
        'FirstRunSetup'       = 'First run: no device selected yet. Enumerating paired devices...'
        'NoDevicesErr'        = 'No paired Bluetooth devices found. Pair your phone/watch in Windows Settings first, then run again.'
        'SelectedDevice'      = 'Selected: {0} ({1})'
        'SavedConfig'         = 'Saved config: {0}'
        'AlreadyRunning'      = 'Proximity Lock is already running in this session.'
    }
    'zh-CN' = @{
        'SelectDeviceTitle'   = '蓝牙远离自动锁 - 选择设备'
        'SelectDeviceLabel'   = '选择一个已配对的蓝牙设备作为您的信任钥匙：'
        'BtnOk'               = '确定'
        'BtnCancel'           = '取消'
        'StatusStarting'      = '状态: 正在启动...'
        'DeviceNone'          = '设备: (无)'
        'DisableMonitoring'   = '禁用监控'
        'EnableMonitoring'    = '启用监控'
        'LockNow'             = '立即锁定工作站'
        'SelectDeviceMenu'    = '选择目标设备...'
        'OpenLogsFolder'      = '打开日志文件夹'
        'OpenConfigFile'      = '打开配置文件'
        'Exit'                = '退出'
        'StartOnLogon'        = '开机自动启动'
        'Status'              = '状态'
        'Device'              = '设备'
        'ProximityLock'       = '蓝牙远离自动锁'
        'MonitoringDisabled'  = '监控已禁用。'
        'MonitoringEnabled'   = '监控已启用。'
        'NoPairedDevices'     = '未找到已配对的设备。'
        'NowTracking'         = '当前跟踪: {0}'
        'LockWarningTitle'    = '远离锁屏警告'
        'LockWarningMessage'  = '设备已断开 ({0})。工作站将在 {1} 秒后锁定。'
        'CliHeader'           = '=== 选择目标蓝牙设备 ==='
        'CliVisible'          = '当前机器可见的已配对设备：'
        'CliPrompt'           = '请输入数字 (1-{0})'
        'CliInvalid'          = '输入无效，请重试。'
        'FirstRunSetup'       = '首次运行：尚未选择设备。正在枚举已配对的设备...'
        'NoDevicesErr'        = '未找到已配对的蓝牙设备。请先在 Windows 设置中配对您的手机/手表，然后重试。'
        'SelectedDevice'      = '已选择: {0} ({1})'
        'SavedConfig'         = '已保存配置: {0}'
        'AlreadyRunning'      = '此会话中已在运行 Proximity Lock。'
    }
}

$script:CurrentCulture = 'en-US'
if ([System.Globalization.CultureInfo]::CurrentUICulture.Name -match '^zh') {
    $script:CurrentCulture = 'zh-CN'
}

function Get-LocaleString {
    param(
        [Parameter(Mandatory)] [string]$Key,
        [object[]]$FormatArgs
    )
    $dict = $script:LocStrings[$script:CurrentCulture]
    if (-not $dict) { $dict = $script:LocStrings['en-US'] }
    $val = $dict[$Key]
    if (-not $val) {
        $val = $script:LocStrings['en-US'][$Key]
    }
    if (-not $val) { return $Key }
    if ($FormatArgs) {
        return $val -f $FormatArgs
    }
    return $val
}
