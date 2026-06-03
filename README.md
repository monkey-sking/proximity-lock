# Proximity Lock

**Language**: **English** · [中文](README.zh-CN.md)

A modern Windows Bluetooth proximity auto-lock built on PowerShell 5.1 + WinRT — the spiritual successor to BTProx.

It watches a paired Bluetooth device (your phone, watch, etc.) and locks the workstation after a configurable delay once the device drops off — optionally running hook scripts on lock / unlock. Full structured logging makes it easy to debug.

> ⚠️ Windows 10 (build 19041+) / Windows 11 only. Calls into the `Windows.Devices.Bluetooth` WinRT namespace.

---

## 1. Install & first-run setup

No runtime to install — the system-bundled PowerShell 5.1 is enough. Drop the folder anywhere (e.g. `D:\Program Files\blue`), then:

```powershell
# Option 1: debug launch with a console window (first run picks the target device interactively)
.\Start-ProximityLock.cmd

# Option 2: silent launch (recommended; no console window)
wscript .\Start-ProximityLock.vbs
```

The first run will:
1. Enumerate Bluetooth devices already **paired** in Windows Settings;
2. Prompt you to pick one as the "trusted key" (console menu or WinForms dialog, picked automatically based on whether a console is attached);
3. Write `config.json` next to the program.

Subsequent launches just read the config.

## 2. Auto-start at logon

```powershell
# Register (writes to HKCU:\...\Run, current user only)
.\Install-Startup.ps1 -Action Install

# Inspect
.\Install-Startup.ps1 -Action Status

# Remove
.\Install-Startup.ps1 -Action Uninstall
```

Auto-start invokes `Start-ProximityLock.vbs` — no console window, no taskbar entry, just the system tray icon.

## 3. Tray menu

- **Status / Device**: current state and bound device (read-only)
- **Disable / Enable monitoring**: pause / resume
- **Lock workstation now**: lock immediately, skipping the countdown
- **Select target device...**: switch the bound device
- **Open logs folder**: open the log directory
- **Open config file**: open the config in Notepad
- **Exit**: quit

## 4. `config.json`

```jsonc
{
  "version": 1,
  "device": {
    "id": "Bluetooth#Bluetooth00:1a:7d:...",  // filled on first run — don't hand-edit
    "name": "iPhone",
    "kind": "classic",       // classic | le | auto
    "bluetoothAddress": null // LE 64-bit MAC, filled automatically
  },
  "monitor": {
    "pollIntervalSeconds": 3,        // connection-state poll interval
    "useRssi": false,                // enable RSSI weak-signal detection (LE only)
    "rssiThresholdDbm": -85,         // below this is considered "away"
    "rssiSustainSeconds": 15,        // signal must stay below threshold this long
    "rssiAdvertisementTtl": 30,      // no advert for this long = signal lost
    "disconnectedSustainSeconds": 30,// sustain debounce before trusting "disconnected"
    "activeProbeEnabled": true,      // SDP active probe for classic BT (strongly recommended)
    "activeProbeAfterSeconds": 0,    // run probe after N s of cached-disconnected (0 = every tick)
    "reconnectStableSeconds": 6      // require N s of continuous successful probes before clearing the sustain timer (prevents single blips on a flaky classic-BT link from defeating the lock)
  },
  "lock": {
    "delaySeconds": 10,              // countdown after device drops off
    "cancelOnReconnect": true,       // reconnect during countdown cancels the lock
    "gracePeriodSeconds": 30,        // suppress lock for N s after start / unlock (0 to disable)
    "requireIdleSeconds": 30         // user must have been idle this long before locking (0 to disable)
  },
  "hooks": {
    "onLock":   "scripts/on-lock.example.bat",
    "onUnlock": "scripts/on-unlock.example.bat",
    "timeoutSeconds": 30,
    "runHidden": true
  },
  "logging": {
    "directory": "logs",             // relative paths resolve from program root
    "level": "INFO",                 // DEBUG / INFO / WARN / ERROR
    "maxBytes": 5242880,             // rotate at 5 MB
    "keepFiles": 10,                 // rolling history
    "echoToConsole": false
  },
  "autoStart": {
    "startEnabled": true             // begin monitoring on launch
  }
}
```

Changes take effect on **restart** (Tray → Exit → relaunch the starter).

## 5. Hook scripts

`.bat` / `.cmd` / `.ps1` / `.exe` are all supported. Paths in `config.json` resolve relative to the program root.

- `onLock`: fired right after the lock, in parallel (does not block the main flow)
- `onUnlock`: fired on Windows unlock
- stdout / stderr go to the log (INFO / WARN)
- exit code 0 → INFO, non-zero → WARN
- exceeding `timeoutSeconds` → killed and logged as WARN

Typical use (see `scripts/on-lock.example.bat`):

```bat
@echo off
REM Pause media, turn the monitor off, kill smart lights
nircmd sendkeypress media_play_pause
nircmd monitor off
curl -s http://homeassistant/api/.../light.desk/turn_off > nul
exit /b 0
```

## 6. Logging

Daily files: `logs/proximity_lock_YYYYMMDD.log`. When a single file exceeds `maxBytes`, it rotates as `.1`, `.2`, ... up to `keepFiles`.

Format: `YYYY-MM-DD HH:mm:ss.fff [LEVEL] [Module] message`

Levels:
- **DEBUG**: poll details, countdown ticks, RSSI samples — off by default; flip `"level": "DEBUG"` or pass `-DebugLog`
- **INFO**: start / device bind / state transitions / lock fired / hook completion
- **WARN**: reconnect during countdown (cancel), hook non-zero exit, hook timeout
- **ERROR**: API failure, fatal errors

> Probe noise: repeated `Active probe failed` lines from classic BT are at DEBUG. Only **state transitions** (lost ↔ recovered) are logged at INFO.

## 7. RSSI weak-signal detection (optional)

Works only on **BLE devices** (fitness bands, AirPods, some smart watches). Enable by setting the device kind to `le` and `monitor.useRssi: true`.

Phones (iPhone in particular) connect as classic Bluetooth, so they fall back to the connect/disconnect signal only.

## 8. CLI flags

```
ProximityLock.ps1 [-ConfigPath <path>] [-ResetDevice] [-NoTray] [-DebugLog]
```

- `-ConfigPath`: use a custom config (default `./config.json`)
- `-ResetDevice`: ignore the saved device and re-prompt
- `-NoTray`: run without the tray (debugging or service contexts)
- `-DebugLog`: force DEBUG-level logging for this run

## 9. Troubleshooting

| Symptom | Investigation |
| --- | --- |
| Startup fails with "No paired Bluetooth devices found" | Pair the device in Windows Settings → Bluetooth first |
| Shows disconnected but it's actually nearby | Classic Bluetooth `ConnectionStatus` doesn't refresh on its own; `monitor.activeProbeEnabled` (default true) issues an SDP query to force the stack to talk. `lock.requireIdleSeconds` (default 30 s) also guards against "BT says you left but you're typing" |
| Locks immediately after launch / unlock | `lock.gracePeriodSeconds` (default 30 s) suppresses lock during the warm-up window — raise it if it still fires |
| Brief BT glitches trigger lock | Raise `lock.delaySeconds`, confirm `cancelOnReconnect: true`, and/or raise `monitor.disconnectedSustainSeconds` |
| Want to disable the idle gate | Set `lock.requireIdleSeconds` to 0 |
| Hook didn't run | Check today's log for `[Hook]` lines — stdout/stderr and exit code are recorded |
| Silent mode shows no tray | Verify a PowerShell process is running and the log is updating; usually the first run failed because no console was available for the device picker — run the `.cmd` once first |

## 10. Layout

```
blue/
├── ProximityLock.ps1            main program
├── Start-ProximityLock.vbs      silent launcher (no window)
├── Start-ProximityLock.cmd      debug launcher (console)
├── Install-Startup.ps1          auto-start registrar
├── config.example.json          config template
├── config.json                  actual config (generated on first run, git-ignored)
├── lib/
│   ├── Logger.ps1               leveled log + rotation
│   ├── Config.ps1               JSON config read/write
│   ├── WinRT.ps1                WinRT async bridge
│   ├── Bluetooth.ps1            enumerate / connect / RSSI / SDP active probe
│   ├── Idle.ps1                 user idle time query
│   ├── Lock.ps1                 LockWorkStation + hook execution
│   ├── Session.ps1              session lock/unlock event listener
│   └── Tray.ps1                 system tray UI
├── scripts/
│   ├── on-lock.example.bat
│   └── on-unlock.example.bat
└── logs/                        runtime logs
```

## 11. Feature matrix

| Capability | Where it lives |
| --- | --- |
| Bluetooth bind / enumerate paired | `lib/Bluetooth.ps1` `Get-PairedBluetoothDevices` |
| Disconnect detection | `Invoke-PollTick` polls `ConnectionStatus` |
| RSSI weak-signal detection | `BluetoothLEAdvertisementWatcher` + sustain timer |
| Configurable countdown | `Start-Countdown`, 1 s tick |
| Cancel-on-reconnect | `cancelOnReconnect`, re-checked every countdown tick |
| LockWorkStation | `lib/Lock.ps1` `Invoke-WorkstationLock` (P/Invoke user32) |
| Instant Monitor Power Off | `lib/Lock.ps1` `Invoke-WorkstationLock` (Sends SC_MONITORPOWER=2) |
| Monitor Auto Wake on Reconnect | `Invoke-PollTick` + `lib/Lock.ps1` `Invoke-ScreenWake` |
| UI Localization (i18n) | `lib/I18n.ps1` (English and Simplified Chinese) |
| OnLock / OnUnlock hooks | `Invoke-LockSequence`, `Register-SessionEvents` |
| Leveled log w/ timestamp + module | `lib/Logger.ps1` |
| Daily + size-based rotation | `Update-LogFilePath` + `Test-LogRotate` |
| Low CPU & Memory footprint | Configurable poll (default 3 s), explicit `[System.GC]::Collect()` on poll ticks |
| Persistent system tray | `lib/Tray.ps1` |
| No admin rights | runs as the current user |

## License

No license declared — pick one (MIT / Apache-2.0 / etc.) before others can re-use it. Until then, all rights reserved by the author.
