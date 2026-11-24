' Starts SX Studio with no console window (the GUI opens as its own app window).
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
' always the 64-bit PowerShell: started by a 32-bit program (the installer's "Open SX Studio now") plain powershell.exe
' is the 32-bit one, which looks for ShowXpress in Program Files (x86)
ps = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%SystemRoot%")
If fso.FileExists(ps & "\Sysnative\WindowsPowerShell\v1.0\powershell.exe") Then ps = ps & "\Sysnative\WindowsPowerShell\v1.0\powershell.exe" Else ps = ps & "\System32\WindowsPowerShell\v1.0\powershell.exe"
CreateObject("WScript.Shell").Run """" & ps & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\df_aim_gui.ps1""", 0, False
