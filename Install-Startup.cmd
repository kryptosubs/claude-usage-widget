@echo off
REM Adds (or removes) the widget from Windows startup, then launches it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
 "$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk';" ^
 "if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host 'Removed from startup.' }" ^
 "else { $s=(New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath='wscript.exe';" ^
 "$s.Arguments='\"%~dp0Start-Widget.vbs\"'; $s.WorkingDirectory='%~dp0'; $s.Save(); Write-Host 'Added to startup.' }"
start "" wscript.exe "%~dp0Start-Widget.vbs"
