' Generic invisible launcher for scheduled tasks.
' Usage: wscript.exe run-hidden.vbs <ps1-path> [arg1 arg2 ...]
' Runs pwsh.exe with the given .ps1 file (and forwards any extra args),
' fully hidden (no console flash).

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

Dim shell, cmd, ps1, extraArgs, i, a
Set shell = CreateObject("WScript.Shell")
ps1 = WScript.Arguments(0)

' Forward arguments 1..N to the powershell script verbatim.
extraArgs = ""
For i = 1 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    ' If an arg contains a space or quote, wrap it in double quotes (with " escaped as "").
    If InStr(a, " ") > 0 Or InStr(a, """") > 0 Then
        a = """" & Replace(a, """", """""") & """"
    End If
    extraArgs = extraArgs & " " & a
Next

cmd = """C:\Program Files\PowerShell\7\pwsh.exe"" -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """" & extraArgs
' 0 = hidden window, True = wait for completion
shell.Run cmd, 0, True
