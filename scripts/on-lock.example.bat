@echo off
REM on-lock.example.bat -- runs when workstation locks.
REM Replace with your own actions. Exit 0 means success.

REM Example 1: simulate Media Play/Pause key (requires nircmd.exe in PATH or same dir)
REM nircmd sendkeypress media_play_pause

REM Example 2: turn the monitor off
REM nircmd monitor off

REM Example 3: log to a custom file
echo %DATE% %TIME% locked >> "%~dp0custom-actions.log"

exit /b 0
