' The PowerShell SX Studio's updater opens this file when the installer is done.
' It starts the app that replaced it.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run """" & dir & "\sx_studio.exe""", 1, False
