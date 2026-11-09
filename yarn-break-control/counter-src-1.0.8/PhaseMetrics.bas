Attribute VB_Name = "PhaseMetrics"
Option Explicit

' Bounded, best-effort local diagnostics. Never change counter state or delivery.
Private Const PHASE_COUNT As Integer = 25
Private Const FLUSH_INTERVAL_MS As Double = 60000#
Private Const TICK_MODULUS As Double = 4294967296#
Private Const MAX_FILE_BYTES As Long = 1048576
Private Const MAX_TOTAL_MS As Double = 1000000000000000#
Private Const CSV_HEADER As String = "utc,window_start_utc,window_end_utc,build,port,phase,count,total_ms,max_ms,over30_count"

Private Type PhaseAggregate
    Count As Long
    TotalMs As Double
    MaxMs As Double
    Over30 As Long
End Type
Private Type SYSTEMTIME
    Year As Integer
    Month As Integer
    DayOfWeek As Integer
    Day As Integer
    Hour As Integer
    Minute As Integer
    Second As Integer
    Milliseconds As Integer
End Type
Private Declare Function GetTickCount Lib "kernel32" () As Long
Private Declare Sub GetSystemTime Lib "kernel32" (ByRef value As SYSTEMTIME)
Private Declare Function GetFileAttributesW Lib "kernel32" (ByVal path As Long) As Long
Private Declare Function CreateFileW Lib "kernel32" (ByVal path As Long, ByVal access As Long, ByVal share As Long, ByVal security As Long, ByVal disposition As Long, ByVal flags As Long, ByVal template As Long) As Long
Private Declare Function GetFileSize Lib "kernel32" (ByVal handle As Long, ByRef high As Long) As Long
Private Declare Function SetFilePointer Lib "kernel32" (ByVal handle As Long, ByVal distance As Long, ByVal high As Long, ByVal method As Long) As Long
Private Declare Function WriteFile Lib "kernel32" (ByVal handle As Long, buffer As Any, ByVal count As Long, ByRef actual As Long, ByVal overlapped As Long) As Long
Private Declare Function CloseHandle Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function MoveFileExW Lib "kernel32" (ByVal source As Long, ByVal destination As Long, ByVal flags As Long) As Long

Private mValues(0 To 8, 1 To PHASE_COUNT) As PhaseAggregate
Private mFolder As String
Private mActive As Boolean
Private mWindowStart As String
Private mLastAttempt As Double
Private mProblem As String
#If PERF_TEST Then
Private mTestClockEnabled As Boolean
Private mTestClock As Double
Private mTestFileLimit As Long
#End If

Private Function MetricsTick() As Double
    Dim value As Long
#If PERF_TEST Then
    If mTestClockEnabled Then MetricsTick = mTestClock: Exit Function
#End If
    value = GetTickCount()
    MetricsTick = value
    If value < 0 Then MetricsTick = CDbl(value) + TICK_MODULUS
End Function

Private Function Elapsed(ByVal before As Double, ByVal after As Double) As Double
    Elapsed = after - before
    If Elapsed < 0# Then Elapsed = Elapsed + TICK_MODULUS
End Function

Private Function UtcText() As String
    Dim value As SYSTEMTIME, atUtc As Date
    GetSystemTime value
    atUtc = DateSerial(value.Year, value.Month, value.Day) + TimeSerial(value.Hour, value.Minute, value.Second)
    UtcText = Format$(atUtc, "yyyy-mm-dd\Thh:nn:ss") & "." & Right$("000" & CStr(value.Milliseconds), 3) & "Z"
End Function

Private Function FileLimit() As Long
    FileLimit = MAX_FILE_BYTES
#If PERF_TEST Then
    If mTestFileLimit > 0 Then FileLimit = mTestFileLimit
#End If
End Function

Private Function PhaseName(ByVal index As Integer) As String
    Select Case index
        Case 1: PhaseName = "runtime-step"
        Case 2: PhaseName = "export-service"
        Case 3: PhaseName = "export-stage"
        Case 4: PhaseName = "export-pulse-read"
        Case 5: PhaseName = "export-worker-check"
        Case 6: PhaseName = "identity-check"
        Case 7: PhaseName = "read-mark"
        Case 8: PhaseName = "comm-before"
        Case 9: PhaseName = "head-read"
        Case 10: PhaseName = "comm-after"
        Case 11: PhaseName = "state-save"
        Case 12: PhaseName = "head-publish"
        Case 13: PhaseName = "display-publish"
        Case 14: PhaseName = "retry-end"
        Case 15: PhaseName = "status-request"
        Case 16: PhaseName = "summary-publish"
        Case 17 To 24: PhaseName = "accepted-interval-h" & CStr(index - 16)
        Case 25: PhaseName = "poll-interval"
    End Select
End Function

Private Function PhaseIndex(ByVal phase As String) As Integer
    Dim index As Integer
    If Len(phase) > 32 Then Exit Function
    For index = 1 To PHASE_COUNT
        If phase = PhaseName(index) Then PhaseIndex = index: Exit Function
    Next index
End Function

Public Sub PerfStart(ByVal folder As String)
    Dim attributes As Long
    On Error GoTo Failed
    If mActive Then PerfStop
    Erase mValues
    mActive = False: mFolder = "": mProblem = ""
    If Len(folder) < 4 Or Len(folder) > 32000 Or Mid$(folder, 2, 2) <> ":\" Or InStr(folder, vbNullChar) > 0 Then
        mProblem = "Performance folder must be an absolute local path": Exit Sub
    End If
    If Right$(folder, 1) = "\" Then folder = Left$(folder, Len(folder) - 1)
    attributes = GetFileAttributesW(StrPtr(folder))
    If attributes = -1 Or (attributes And 16&) = 0 Then
        mProblem = "Performance folder is unavailable": Exit Sub
    End If
    mFolder = folder
    mWindowStart = UtcText(): mLastAttempt = MetricsTick()
    mActive = True
    Exit Sub
Failed:
    mProblem = "Performance start failed: " & Err.Description
    mActive = False
End Sub

Public Sub PerfRecord(ByVal port As Integer, ByVal phase As String, ByVal elapsedMs As Double)
    Dim index As Integer
    On Error GoTo Failed
    If Not mActive Then Exit Sub
    If port < 0 Or port > 8 Then mProblem = "Invalid performance port": Exit Sub
    index = PhaseIndex(phase)
    If index = 0 Then mProblem = "Invalid performance phase": Exit Sub
    If Not (elapsedMs >= 0# And elapsedMs < TICK_MODULUS) Then
        mProblem = "Invalid performance duration": Exit Sub
    End If
    With mValues(port, index)
        If .Count = &H7FFFFFFF Or .TotalMs > MAX_TOTAL_MS - elapsedMs Then
            mProblem = "Performance aggregate limit reached": Exit Sub
        End If
        .Count = .Count + 1
        .TotalMs = .TotalMs + elapsedMs
        If elapsedMs > .MaxMs Then .MaxMs = elapsedMs
        If elapsedMs > 30000# Then .Over30 = .Over30 + 1
    End With
    Exit Sub
Failed:
    mProblem = "Performance record failed: " & Err.Description
End Sub

Private Function Rows(ByVal atUtc As String) As String
    Dim port As Integer, index As Integer, row As String
    For port = 0 To 8
        For index = 1 To PHASE_COUNT
            With mValues(port, index)
                If .Count > 0 Then
                    row = atUtc & "," & mWindowStart & "," & atUtc & ",1.0.5," & CStr(port) & "," & PhaseName(index)
                    row = row & "," & CStr(.Count) & "," & Trim$(Str$(.TotalMs)) & "," & Trim$(Str$(.MaxMs)) & "," & CStr(.Over30) & vbCrLf
                    Rows = Rows & row
                End If
            End With
        Next index
    Next port
End Function

Private Function AppendRows(ByVal rowsText As String) As Boolean
    Dim path As String, previous As String, handle As Long, size As Long, high As Long
    Dim text As String, bytes() As Byte, count As Long, actual As Long, offset As Long
    Dim code As Long, limit As Long
    On Error GoTo Failed
    path = mFolder & "\poll-performance.csv"
    previous = mFolder & "\poll-performance.previous.csv"
    limit = FileLimit()
    If Len(CSV_HEADER & vbCrLf & rowsText) > limit Then
        mProblem = "Performance window exceeds file limit": Exit Function
    End If
    handle = CreateFileW(StrPtr(path), &H40000000, 1, 0, 4, &H80, 0)
    If handle = -1 Then handle = 0: GoTo WindowsFailure
    size = GetFileSize(handle, high)
    If size = -1 Then GoTo WindowsFailure
    If high <> 0 Or size > limit - Len(rowsText) Then
        CloseHandle handle: handle = 0
        If MoveFileExW(StrPtr(path), StrPtr(previous), 1) = 0 Then GoTo WindowsFailure
        handle = CreateFileW(StrPtr(path), &H40000000, 1, 0, 2, &H80, 0)
        If handle = -1 Then handle = 0: GoTo WindowsFailure
        size = 0
    End If
    text = rowsText
    If size = 0 Then text = CSV_HEADER & vbCrLf & text
    If SetFilePointer(handle, 0, 0, 2) = -1 Then GoTo WindowsFailure
    bytes = StrConv(text, vbFromUnicode)
    count = UBound(bytes) + 1
    Do While offset < count
        actual = 0
        If WriteFile(handle, bytes(offset), count - offset, actual, 0) = 0 Then GoTo WindowsFailure
        If actual <= 0 Then mProblem = "Performance write made no progress": GoTo Cleanup
        offset = offset + actual
    Loop
    If CloseHandle(handle) = 0 Then handle = 0: GoTo WindowsFailure
    handle = 0
    AppendRows = True
Cleanup:
    If handle <> 0 Then CloseHandle handle
    Exit Function
WindowsFailure:
    code = Err.LastDllError
    mProblem = "Performance file unavailable (Windows " & CStr(code) & ")"
    GoTo Cleanup
Failed:
    mProblem = "Performance write failed: " & Err.Description
    Resume Cleanup
End Function

Public Sub PerfFlush(Optional ByVal force As Boolean = False)
    Dim tick As Double, atUtc As String, text As String
    On Error GoTo Failed
    If Not mActive Then Exit Sub
    tick = MetricsTick()
    If Not force And Elapsed(mLastAttempt, tick) < FLUSH_INTERVAL_MS Then Exit Sub
    ' Failed diagnostics retry once per minute; preserve the aggregates meanwhile.
    mLastAttempt = tick
    atUtc = UtcText(): text = Rows(atUtc)
    If Len(text) > 0 Then
        If Not AppendRows(text) Then Exit Sub
    End If
    Erase mValues
    mWindowStart = atUtc: mProblem = ""
    Exit Sub
Failed:
    mProblem = "Performance flush failed: " & Err.Description
End Sub

Public Function PerfProblem() As String
    On Error Resume Next
    PerfProblem = mProblem
End Function

Public Sub PerfStop()
    On Error GoTo Failed
    PerfFlush True
    mActive = False: mFolder = ""
    Exit Sub
Failed:
    mProblem = "Performance stop failed: " & Err.Description
    mActive = False
End Sub

#If PERF_TEST Then
Public Sub PerfTestSetClock(ByVal tick As Double)
    mTestClockEnabled = True: mTestClock = tick
End Sub

Public Sub PerfTestFileLimit(ByVal bytes As Long)
    If bytes >= 512 And bytes <= MAX_FILE_BYTES Then mTestFileLimit = bytes Else mTestFileLimit = 0
End Sub
#End If
