# WinRT.ps1 -- Async bridge for WinRT IAsyncOperation/IAsyncAction from PS 5.1

Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop

# Force-load required WinRT namespaces (PS 5.1 only resolves on first reference)
[Windows.Foundation.IAsyncOperation`1, Windows.Foundation, ContentType=WindowsRuntime]    | Out-Null
[Windows.Foundation.IAsyncAction, Windows.Foundation, ContentType=WindowsRuntime]         | Out-Null
[Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]       | Out-Null
[Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]     | Out-Null
[Windows.Devices.Bluetooth.BluetoothCacheMode, Windows.Devices.Bluetooth, ContentType=WindowsRuntime]    | Out-Null
[Windows.Devices.Bluetooth.Rfcomm.RfcommDeviceServicesResult, Windows.Devices.Bluetooth, ContentType=WindowsRuntime] | Out-Null
[Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType=WindowsRuntime] | Out-Null

# Resolve AsTask overloads via reflection
$script:AsTaskMI_Op     = $null
$script:AsTaskMI_Action = $null

foreach ($mi in [System.WindowsRuntimeSystemExtensions].GetMethods()) {
    if ($mi.Name -ne 'AsTask') { continue }
    $pars = $mi.GetParameters()
    if ($pars.Count -ne 1) { continue }
    $pName = $pars[0].ParameterType.Name
    if ($mi.IsGenericMethod -and $pName -eq 'IAsyncOperation`1' -and -not $script:AsTaskMI_Op) {
        $script:AsTaskMI_Op = $mi
    } elseif (-not $mi.IsGenericMethod -and $pName -eq 'IAsyncAction' -and -not $script:AsTaskMI_Action) {
        $script:AsTaskMI_Action = $mi
    }
}

if (-not $script:AsTaskMI_Op -or -not $script:AsTaskMI_Action) {
    throw "Failed to resolve WindowsRuntimeSystemExtensions.AsTask overloads"
}

function Await {
    param(
        [Parameter(Mandatory, Position=0)] $AsyncOp,
        [Parameter(Mandatory, Position=1)] [type] $ResultType,
        [Parameter(Position=2)] [int] $TimeoutMs = 15000
    )
    $mi = $script:AsTaskMI_Op.MakeGenericMethod($ResultType)
    $task = $mi.Invoke($null, @($AsyncOp))
    if (-not $task.Wait($TimeoutMs)) {
        throw "WinRT async operation timed out after ${TimeoutMs}ms"
    }
    return $task.Result
}

function AwaitAction {
    param(
        [Parameter(Mandatory, Position=0)] $AsyncAction,
        [Parameter(Position=1)] [int] $TimeoutMs = 15000
    )
    $task = $script:AsTaskMI_Action.Invoke($null, @($AsyncAction))
    if (-not $task.Wait($TimeoutMs)) {
        throw "WinRT async action timed out after ${TimeoutMs}ms"
    }
}
