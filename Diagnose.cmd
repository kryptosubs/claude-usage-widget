@echo off
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0ClaudeUsageWidget.ps1" -Diagnose
echo.
pause
