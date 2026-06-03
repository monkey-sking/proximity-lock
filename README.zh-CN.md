# Proximity Lock

**语言 / Language**: [English](README.md) · **中文**

基于 PowerShell 5.1 + WinRT 的现代 Windows 蓝牙近程自动锁屏工具，BTProx 的精神继任者。

监测一台已配对的蓝牙设备（手机 / 手表），在你离开电脑、设备失联后按可配置的延迟自动锁屏，并可挂载锁屏 / 解锁脚本。完整运行日志，方便排查。

> ⚠️ 仅支持 Windows 10 (build 19041+) / Windows 11。底层调用 `Windows.Devices.Bluetooth` 命名空间。

---

## 1. 安装与首次配置

无需安装运行时（系统自带 PowerShell 5.1 即可）。把整个目录放到任意位置（推荐 `D:\Program Files (x86)\blue`），然后：

```powershell
# 方式一：调试模式，带控制台输出，首次运行会让你选择目标设备
.\Start-ProximityLock.cmd

# 方式二：静默启动（推荐，无控制台窗口）
wscript .\Start-ProximityLock.vbs
```

首次运行会：
1. 枚举已在 Windows 系统设置中**配对**的蓝牙设备；
2. 让你选择一台作为「信任密钥」（控制台菜单或 WinForms 对话框，按当前是否有控制台自动选择）；
3. 在程序目录生成 `config.json`。

之后再启动会直接读取配置。

## 2. 开机自启

```powershell
# 注册（写入 HKCU:\...\Run，仅当前用户）
.\Install-Startup.ps1 -Action Install

# 查看状态
.\Install-Startup.ps1 -Action Status

# 取消
.\Install-Startup.ps1 -Action Uninstall
```

自启项调用的就是 `Start-ProximityLock.vbs`，无窗口、无任务栏图标，仅有系统托盘存在。

## 3. 系统托盘菜单

- **Status / Device**: 当前状态与目标设备（只读）
- **Disable / Enable monitoring**: 暂时停 / 开
- **Lock workstation now**: 手动立即锁屏（不走倒计时）
- **Select target device...**: 切换目标设备
- **Open logs folder**: 打开日志目录
- **Open config file**: 用记事本打开配置
- **Exit**: 退出程序

## 4. 配置文件 `config.json`

```jsonc
{
  "version": 1,
  "device": {
    "id": "Bluetooth#Bluetooth00:1a:7d:...",  // 首次启动自动填充，不要手改
    "name": "iPhone",
    "kind": "classic",       // classic | le | auto
    "bluetoothAddress": null // LE 设备的 64-bit MAC，自动填充
  },
  "monitor": {
    "pollIntervalSeconds": 3,        // 连接状态轮询间隔
    "useRssi": false,                // 启用 RSSI 弱信号判定（仅 LE 设备）
    "rssiThresholdDbm": -85,         // 低于此 dBm 视为离位
    "rssiSustainSeconds": 15,        // 信号需持续低于阈值多少秒
    "rssiAdvertisementTtl": 30,      // 多久没收到广播视为信号丢失
    "disconnectedSustainSeconds": 30,// 连续多少秒判定 disconnected 才算真断开（去抖）
    "activeProbeEnabled": true,      // 经典 BT 设备启用 SDP 主动探测（强烈推荐）
    "activeProbeAfterSeconds": 0,    // 缓存状态显示 disconnected 多少秒后主动探测（0 = 每个 tick）
    "reconnectStableSeconds": 6      // 断开后需要连续多少秒成功探测才算真恢复（防止经典蓝牙偶发闪连导致 sustain 计时器被反复清零）
  },
  "lock": {
    "delaySeconds": 10,              // 离位后的缓冲倒计时
    "cancelOnReconnect": true,       // 倒计时期间恢复则取消锁定（防误触）
    "gracePeriodSeconds": 30,        // 启动 / 解锁后多少秒内禁锁（让 BT 栈稳定，设 0 关闭）
    "requireIdleSeconds": 30         // 用户至少多少秒没碰键鼠才允许锁屏（设 0 关闭此判定）
  },
  "hooks": {
    "onLock":   "scripts/on-lock.example.bat",
    "onUnlock": "scripts/on-unlock.example.bat",
    "timeoutSeconds": 30,
    "runHidden": true
  },
  "logging": {
    "directory": "logs",             // 相对路径基于程序目录
    "level": "INFO",                 // DEBUG / INFO / WARN / ERROR
    "maxBytes": 5242880,             // 单文件 5MB
    "keepFiles": 10,                 // 滚动保留份数
    "echoToConsole": false           // 是否同时输出到控制台
  },
  "autoStart": {
    "startEnabled": true             // 启动后默认即开启监测
  }
}
```

修改后**重启程序**生效（托盘右键 Exit → 重启动启动器）。

## 5. 自定义脚本钩子

支持 `.bat` / `.cmd` / `.ps1` / `.exe`。脚本路径在 `config.json` 中配置，相对路径基于程序根目录。

- `onLock`: 锁屏触发后立即并行启动（不阻塞主流程）
- `onUnlock`: Windows 解锁事件触发后启动
- stdout / stderr 会被分别记录到日志（INFO / WARN）
- 退出码 0 = INFO，非 0 = WARN
- 超过 `timeoutSeconds` 强制 kill 并记录 WARN

典型用法（参考 `scripts/on-lock.example.bat`）：

```bat
@echo off
REM 暂停媒体播放、关显示器、关智能灯
nircmd sendkeypress media_play_pause
nircmd monitor off
curl -s http://homeassistant/api/.../light.desk/turn_off > nul
exit /b 0
```

## 6. 日志

按天生成：`logs/proximity_lock_YYYYMMDD.log`，单文件超过 `maxBytes` 时滚动为 `.1` `.2` ... 至 `keepFiles` 上限。

格式：`YYYY-MM-DD HH:mm:ss.fff [LEVEL] [Module] message`

层级：
- **DEBUG**: 轮询细节、倒计时读秒、RSSI 数值 —— 默认关闭，配置 `"level": "DEBUG"` 或加 `-DebugLog` 参数启用
- **INFO**:  启动 / 绑定设备 / 状态切换 / 锁屏触发 / 脚本完成
- **WARN**:  倒计时中恢复（误触保护）、脚本非 0 退出、脚本超时
- **ERROR**: API 调用失败、严重错误

## 7. RSSI 弱信号判定（可选拓展）

仅适用于 **BLE 设备**（手环、AirPods、部分智能手表）。
开启方法：将目标设备类型保存为 `le`，并设置 `monitor.useRssi: true`。

iPhone 等手机通常以经典蓝牙模式连接，只能用"连接断开"判定。

## 8. 命令行参数

```
ProximityLock.ps1 [-ConfigPath <path>] [-ResetDevice] [-NoTray] [-DebugLog]
```

- `-ConfigPath`：使用自定义配置文件（默认 `./config.json`）
- `-ResetDevice`：忽略已有设备配置，重新弹出选择菜单
- `-NoTray`：无托盘运行，用于调试或服务化场景
- `-DebugLog`：本次运行强制使用 DEBUG 级别日志

## 9. 排错

| 现象 | 排查思路 |
| --- | --- |
| 启动失败 "No paired Bluetooth devices found" | 先在 Windows 设置 → 蓝牙中完成配对 |
| 一直显示已断开但其实连着 | 经典蓝牙 `ConnectionStatus` 默认不主动刷新；本程序通过 `monitor.activeProbeEnabled`（默认 true）发 SDP 查询强制 BT 栈通信。此外 `lock.requireIdleSeconds`（默认 30s）会拦截"BT 显示断开但你还在打字"的误锁 |
| 启动 / 解锁后立刻又被锁 | `lock.gracePeriodSeconds` 默认 30s 抑制窗口；若仍误锁，调大此值 |
| 蓝牙在短暂飘移时被误锁 | 增大 `lock.delaySeconds`，确认 `cancelOnReconnect: true`；或调大 `monitor.disconnectedSustainSeconds` |
| 想关掉 idle 判定（无论是否在打字都按 BT 判定锁屏） | 将 `lock.requireIdleSeconds` 设为 0 |
| 锁屏脚本未生效 | 看 `logs/` 下当天日志的 `[Hook]` 行，检查 stdout/stderr 与退出码 |
| 静默模式没有托盘 | 检查 `Get-Process powershell` 是否有进程在跑；日志是否在更新；通常是首次运行因为没控制台无法弹设备选择对话框，先用 `.cmd` 启动一次 |

## 10. 文件结构

```
blue/
├── ProximityLock.ps1            主程序
├── Start-ProximityLock.vbs      静默启动器（无窗口）
├── Start-ProximityLock.cmd      调试启动器（带控制台）
├── Install-Startup.ps1          开机自启注册器
├── config.example.json          配置模板
├── config.json                  实际配置（首次运行生成）
├── lib/
│   ├── Logger.ps1               分级日志 + 滚动
│   ├── Config.ps1               JSON 配置读写
│   ├── WinRT.ps1                WinRT 异步桥接
│   ├── Bluetooth.ps1            蓝牙枚举/连接/RSSI/SDP 主动探测
│   ├── Idle.ps1                 用户键鼠 idle 时长查询
│   ├── Lock.ps1                 LockWorkStation + 钩子执行
│   ├── Session.ps1              锁屏/解锁事件监听
│   └── Tray.ps1                 系统托盘 UI
├── scripts/
│   ├── on-lock.example.bat
│   └── on-unlock.example.bat
└── logs/                        运行日志
```

## 11. PRD 对照

| PRD 需求 | 实现位置 |
| --- | --- |
| 蓝牙设备绑定 / 枚举已配对 | `lib/Bluetooth.ps1` `Get-PairedBluetoothDevices` |
| 断开判定 | `Invoke-PollTick` 轮询 `ConnectionStatus` |
| 弱信号 (RSSI) 判定 | `BluetoothLEAdvertisementWatcher` + sustain timer |
| 自定义延迟倒计时 | `Start-Countdown`，1 秒 tick |
| 防误触（恢复即取消） | `cancelOnReconnect`，倒计时内每 tick 复查 |
| 自动锁屏 (LockWorkStation) | `lib/Lock.ps1` `Invoke-WorkstationLock` P/Invoke user32 |
| 锁屏立即黑屏/熄屏 | `lib/Lock.ps1` `Invoke-WorkstationLock` (发送 SC_MONITORPOWER=2 信号) |
| 蓝牙恢复自动点亮屏幕 | `Invoke-PollTick` + `lib/Lock.ps1` `Invoke-ScreenWake` |
| 界面多语言本地化 (i18n) | `lib/I18n.ps1` (支持中英文环境自动切换) |
| OnLock / OnUnlock 钩子 | `Invoke-LockSequence`、`Register-SessionEvents` |
| 分级日志 + 时间戳 + 模块 | `lib/Logger.ps1` |
| 按天文件 + 按大小切分 | `Update-LogFilePath` + `Test-LogRotate` |
| 低 CPU 与内存占用 | 轮询间隔可配（默认 3s），每次轮询显式执行 `[System.GC]::Collect()` |
| 系统托盘常驻 | `lib/Tray.ps1` |
| 无管理员权限 | 默认全部以普通用户运行 |
