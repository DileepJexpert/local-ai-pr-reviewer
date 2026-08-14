Option Explicit

Dim shell, folder, command
Set shell = CreateObject("WScript.Shell")
folder = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
command = "cmd.exe /k """ & folder & "\review.cmd"""
shell.Run command, 1, False
