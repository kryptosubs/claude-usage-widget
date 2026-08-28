' Launches the Claude Usage Widget with no console window.
' Double-click this file to start the widget.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.CurrentDirectory = here
sh.Run "powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & here & "\ClaudeUsageWidget.ps1""", 0, False
