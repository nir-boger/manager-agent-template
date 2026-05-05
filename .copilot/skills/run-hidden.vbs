' Generic invisible launcher for scheduled tasks.
' Usage: wscript.exe run-hidden.vbs <ps1-path>
' Runs pwsh.exe with the given .ps1 file, fully hidden (no console flash).

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

Dim shell, cmd, ps1
Set shell = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)
cmd = """C:\Program Files\PowerShell\7\pwsh.exe"" -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """"
' 0 = hidden window, True = wait for completion
shell.Run cmd, 0, True
