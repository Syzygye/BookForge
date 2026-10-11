Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
basePath = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(basePath, "BookForge.ps1")
powershellPath = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not fso.FileExists(scriptPath) Then
    MsgBox "No se encuentra BookForge.ps1 en la carpeta del programa.", 16, "BookForge 1.0"
    WScript.Quit 1
End If
command = Chr(34) & powershellPath & Chr(34) & " -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
sh.Run command, 0, False
