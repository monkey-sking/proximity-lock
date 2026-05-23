@echo off
REM on-unlock.example.bat -- runs when workstation unlocks.

REM Example: resume music playback
REM nircmd sendkeypress media_play_pause

echo %DATE% %TIME% unlocked >> "%~dp0custom-actions.log"

exit /b 0
