' Starts SX Studio. The PowerShell SX Studio's Update opens this file once the installer is done, and its
' old shortcuts (one pinned to the taskbar stays) open it too. The installer opens the app itself after a
' silent install, so a copy that started in the last minute is left alone instead of starting another.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
On Error Resume Next
Set wmi = GetObject("winmgmts:\\.\root\cimv2")
For Each p In wmi.ExecQuery("SELECT CreationDate FROM Win32_Process WHERE Name = 'sx_studio.exe'")
  Set t = CreateObject("WbemScripting.SWbemDateTime")
  t.Value = p.CreationDate
  If Err.Number = 0 Then
    If DateDiff("s", t.GetVarDate(True), Now) < 60 Then WScript.Quit
  End If
  Err.Clear
Next
On Error GoTo 0
CreateObject("WScript.Shell").Run """" & dir & "\sx_studio.exe""", 1, False
