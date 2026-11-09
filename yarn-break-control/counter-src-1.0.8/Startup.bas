Attribute VB_Name = "Startup"
Option Explicit

Public Sub Main()
    Dim problem As String, folder As String, arguments As String, epoch As String
    On Error GoTo Failed
    arguments = Trim$(Command$)
    If LCase$(arguments) = "/export" Or LCase$(Left$(arguments, 8)) = "/export " Then
        If Len(arguments) > 7 Then
            epoch = Mid$(arguments, 9)
            If Not ExportPulseEpochValid(epoch) Then Err.Raise vbObjectError + 2603, , "Invalid background log helper epoch"
        End If
        ' This role never acquires counter state, creates Vuniq, or opens COM.
        folder = DefaultDataFolder() & "\outbox"
        If Not ExportRun(folder, problem, epoch) Then
            AuditWrite DefaultDataFolder(), "export-worker", 0, 0, problem, problem
        End If
        Exit Sub
    End If
    If LCase$(App.EXEName) = "nilit-export" Then Err.Raise vbObjectError + 2602, , "This is the background log helper. Start nilit.exe instead."
    If Len(Trim$(Command$)) > 0 Then Err.Raise vbObjectError + 2601, , "Unrecognized command line"
    If Not AcquireCounter(problem) Then MsgBox problem, vbExclamation, "NILIT Counter": Exit Sub
    If Not RuntimeStart(problem) Then
        ReleaseCounter
        MsgBox "Counter was not started. Saved data was not reset." & vbCrLf & problem, vbCritical, "NILIT Counter"
        Exit Sub
    End If
    MainForm.Show
    Exit Sub
Failed:
    problem = Err.Description
    RuntimeStop
    MsgBox problem, vbCritical, "NILIT Counter"
End Sub
