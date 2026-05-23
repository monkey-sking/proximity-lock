' Start-ProximityLock.vbs -- silent launcher (no console window)
Set sh = CreateObject("WScript.Shell")
appDir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & appDir & "\ProximityLock.ps1"""
' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
