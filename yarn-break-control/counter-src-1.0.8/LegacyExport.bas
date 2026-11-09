Attribute VB_Name = "LegacyExport"
Option Explicit

' ==================================================================================
' LegacyExport.bas - NILIT Line E/F Direct SAP Log Export
' Restores direct, non-blocking Win32 file append directly inside nilit.exe.
' Replaces the multi-process outbox and eliminates worker timeouts & sharing violations.
'
' Targets:
'   MainLogDir\Log.txt            -> \\192.168.66.100\sap\Log.txt
'   BackLogDir\LogMM-DD-YYYY.txt  -> \\192.168.66.100\sap\Backup\LogMM-DD-YYYY.txt
' Encoding : Windows-1255 (Hebrew, code page 1255), no trailing NUL.
' Sharing  : FILE_SHARE_READ Or FILE_SHARE_WRITE Or FILE_SHARE_DELETE (&H13)
' Lifetime : short-lived open -> seek EOF -> write -> close per event/flush.
' ==================================================================================

' --- Win32 Constants ---
Private Const FILE_SHARE_READ       As Long = &H00000001
Private Const FILE_SHARE_WRITE      As Long = &H00000002
Private Const FILE_SHARE_DELETE     As Long = &H00000010
Private Const FILE_SHARE_ALL        As Long = &H00000013

Private Const GENERIC_WRITE         As Long = &H40000000
Private Const FILE_ATTRIBUTE_NORMAL As Long = &H00000080
Private Const OPEN_ALWAYS           As Long = 4
Private Const FILE_END              As Long = 2
Private Const INVALID_HANDLE_VALUE  As Long = -1
Private Const INVALID_POINTER_VALUE As Long = -1
Private Const CODE_PAGE_1255        As Long = 1255

' --- Win32 APIs ---
Private Declare Function CreateFileW Lib "kernel32" ( _
    ByVal lpFileName As Long, _
    ByVal dwDesiredAccess As Long, _
    ByVal dwShareMode As Long, _
    ByVal lpSecurityAttributes As Long, _
    ByVal dwCreationDisposition As Long, _
    ByVal dwFlagsAndAttributes As Long, _
    ByVal hTemplateFile As Long) As Long

Private Declare Function SetFilePointer Lib "kernel32" ( _
    ByVal hFile As Long, _
    ByVal lDistanceToMove As Long, _
    ByVal lpDistanceToMoveHigh As Long, _
    ByVal dwMoveMethod As Long) As Long

Private Declare Function WriteFile Lib "kernel32" ( _
    ByVal hFile As Long, _
    lpBuffer As Any, _
    ByVal nNumberOfBytesToWrite As Long, _
    lpNumberOfBytesWritten As Long, _
    ByVal lpOverlapped As Long) As Long

Private Declare Function CloseHandle Lib "kernel32" (ByVal hObject As Long) As Long

Private Declare Function WideCharToMultiByte Lib "kernel32" ( _
    ByVal CodePage As Long, _
    ByVal dwFlags As Long, _
    ByVal lpWideCharStr As Long, _
    ByVal cWideChar As Long, _
    lpMultiCharStr As Any, _
    ByVal cMultiChar As Long, _
    ByVal lpDefaultChar As Long, _
    ByVal lpUsedFailChar As Long) As Long

Private Declare Function CreateDirectoryW Lib "kernel32" ( _
    ByVal lpPathName As Long, _
    ByVal lpSecurityAttributes As Long) As Long

Private Function Hebrew(ByVal codes As String) As String
    Dim values() As String, i As Long
    values = Split(codes, " ")
    For i = 0 To UBound(values)
        Hebrew = Hebrew & ChrW$(CLng("&H" & values(i)))
    Next i
End Function

Private Function EventName(ByRef queued As QueuedEvent) As String
    If queued.Kind = "maintenance" Then
        Select Case queued.Maintenance
            Case 1: EventName = Hebrew("5D0 5D7 5D6 5E7 5D4") & "_" & Hebrew("5DB 5DC 5DC 5D9 5EA")
            Case 2: EventName = Hebrew("5D0 5D7 5D6 5E7 5D4") & "_" & Hebrew("5DE 5EA 5D5 5DB 5E0 5E0 5EA")
            Case 3: EventName = Hebrew("5E9 5D9 5E0 5D5 5D9") & "_" & Hebrew("5DE 5D5 5E6 5E8")
            Case 4: EventName = Hebrew("5D8 5D9 5E4 5D5 5DC") & "_" & Hebrew("5D7 5E6 5D9") & "_" & Hebrew("5E9 5E0 5EA 5D9")
            Case 5: EventName = Hebrew("5D4 5E9 5D1 5EA 5D4")
            Case Else: EventName = "MAINT_" & CStr(queued.Maintenance)
        End Select
    Else
        Select Case queued.Mode
            Case 1: EventName = Hebrew("5EA 5E7 5D9 5DF")
            Case 2: EventName = Hebrew("5EA 5E7 5DC 5D4")
            Case 3: EventName = Hebrew("5E0 5D9 5E7 5D9 5D5 5DF")
            Case 4: EventName = Hebrew("5D0 5D7 5D6 5E7 5D4")
            Case 5: EventName = Hebrew("5D0 5D5 5D8 5D5 5DE 5D8")
            Case Else: EventName = "MODE_" & CStr(queued.Mode)
        End Select
        If queued.Kind = "finish" Then EventName = EventName & Hebrew("5E1 5D9 5D5 5DD")
    End If
End Function

Private Function Encode1255(ByVal s As String, ByRef OK As Boolean) As Byte()
    Dim n As Long, m As Long, buf() As Byte
    OK = False
    If Len(s) = 0 Then
        ReDim buf(0 To 0)
        Encode1255 = buf
        Exit Function
    End If

    n = WideCharToMultiByte(CODE_PAGE_1255, 0, StrPtr(s), Len(s), ByVal 0&, 0, ByVal 0&, ByVal 0&)
    If n < 1 Then
        ReDim buf(0 To 0)
        Encode1255 = buf
        Exit Function
    End If

    ReDim buf(0 To n - 1)
    m = WideCharToMultiByte(CODE_PAGE_1255, 0, StrPtr(s), Len(s), buf(0), n, ByVal 0&, ByVal 0&)
    If m < 1 Then
        ReDim buf(0 To 0)
        Encode1255 = buf
        Exit Function
    End If

    OK = True
    Encode1255 = buf
End Function

Private Function AppendToFile(ByVal filePath As String, ByRef data() As Byte) As Boolean
    Dim hFile As Long, nBytes As Long, nWritten As Long
    Dim ret As Long

    AppendToFile = False
    nBytes = UBound(data) - LBound(data) + 1
    If nBytes <= 0 Then Exit Function

    EnsureParentDir filePath

    hFile = CreateFileW(StrPtr(filePath), GENERIC_WRITE, FILE_SHARE_READ Or FILE_SHARE_WRITE, 0, _
                        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    If hFile <> INVALID_HANDLE_VALUE Then
        ret = SetFilePointer(hFile, 0, 0, FILE_END)
        If ret <> INVALID_POINTER_VALUE Or Err.LastDllError = 0 Then
            If WriteFile(hFile, data(LBound(data)), nBytes, nWritten, 0) <> 0 Then
                If nWritten = nBytes Then AppendToFile = True
            End If
        End If
        CloseHandle hFile
        If AppendToFile Then Exit Function
    End If

    ' Reliable fallback: native binary append
    AppendToFile = NativeAppend(filePath, data)
End Function

Private Function NativeAppend(ByVal filePath As String, ByRef data() As Byte) As Boolean
    Dim fn As Integer
    On Error GoTo Failed
    fn = FreeFile
    Open filePath For Binary Access Write As #fn
    Put #fn, LOF(fn) + 1, data
    Close #fn
    NativeAppend = True
    Exit Function
Failed:
    If fn <> 0 Then Close #fn
End Function

Private Sub EnsureParentDir(ByVal filePath As String)
    Dim k As Long, folder As String
    k = InStrRev(filePath, "\")
    If k <= 0 Then Exit Sub
    folder = Left$(filePath, k - 1)
    If Len(folder) = 0 Then Exit Sub
    CreateDirectoryW StrPtr(folder), 0
End Sub

Private Function Joined(ByVal folder As String, ByVal name As String) As String
    If Right$(folder, 1) <> "\" Then folder = folder & "\"
    Joined = folder & name
End Function

' ----------------------------------------------------------------------------------
' Public Contract: ExportStage
' Called synchronously by CounterRuntime.bas for each pending queued event.
' Appends directly to MainLogDir\Log.txt and BackLogDir\LogMM-DD-YYYY.txt.
' ----------------------------------------------------------------------------------
Public Function ExportStage(ByVal folder As String, ByVal epoch As String, ByRef queued As QueuedEvent, _
        ByVal line1 As String, ByVal line2 As String, ByVal mainLogDir As String, _
        ByVal backLogDir As String, ByRef problem As String) As Boolean
    Dim line As String, extruder As Integer
    Dim mainPath As String, backPath As String
    Dim mainRow As String, backRow As String
    Dim encMain() As Byte, encBack() As Byte
    Dim okMain As Boolean, okBack As Boolean

    On Error GoTo Failed
    problem = ""

    If queued.Port <= 4 Then line = line1 Else line = line2
    extruder = queued.Port
    If extruder > 4 Then extruder = extruder - 4

    mainRow = Trim$(Str(queued.OccurredLocal)) & "," & EventName(queued) & "," & line & "," & _
              Format$(extruder) & "," & Format$(queued.Head) & "," & _
              Format$(queued.Minutes \ 60) & ":" & Format$(queued.Minutes Mod 60) & vbCrLf

    backRow = Left$(mainRow, Len(mainRow) - 2) & _
              ",Date-" & Format$(queued.WipingDate) & ",Time-" & Format$(queued.WipingTime) & vbCrLf

    mainPath = Joined(mainLogDir, "Log.txt")
    backPath = Joined(backLogDir, "Log" & Format$(queued.OccurredLocal, "mm-dd-yyyy") & ".txt")

    encMain = Encode1255(mainRow, okMain)
    If Not okMain Then
        problem = "Failed to encode main row to CP1255"
        Exit Function
    End If

    encBack = Encode1255(backRow, okBack)
    If Not okBack Then
        problem = "Failed to encode backup row to CP1255"
        Exit Function
    End If

    If Not AppendToFile(mainPath, encMain) Then
        problem = "Cannot append to main log: " & mainPath & " (Error: " & CStr(Err.LastDllError) & ")"
        Exit Function
    End If

    If Not AppendToFile(backPath, encBack) Then
        problem = "Cannot append to backup log: " & backPath & " (Error: " & CStr(Err.LastDllError) & ")"
        Exit Function
    End If

    ExportStage = True
    Exit Function

Failed:
    problem = "Export stage error: " & Err.Description
End Function

' ----------------------------------------------------------------------------------
' Compatibility Stubs for Background Worker
' Because direct append is now active, child processes and outbox pulses are no longer needed.
' ----------------------------------------------------------------------------------
Public Function ExportRun(ByVal folder As String, ByRef problem As String, Optional ByVal statusEpoch As String = "") As Boolean
    problem = ""
    ExportRun = True
End Function

Public Function ExportStatus(ByVal folder As String, ByRef pendingCount As Long, ByRef uncertainCount As Long, ByRef problem As String) As Boolean
    pendingCount = 0
    uncertainCount = 0
    problem = ""
    ExportStatus = True
End Function
