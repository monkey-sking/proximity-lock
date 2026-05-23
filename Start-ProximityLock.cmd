@echo off
REM Start-ProximityLock.cmd -- launcher with visible console (debug)
setlocal
set "APPDIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%ProximityLock.ps1" %*
endlocal
