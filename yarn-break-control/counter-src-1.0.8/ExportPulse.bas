Attribute VB_Name = "ExportPulse"
Option Explicit

' A UI read opens exactly one bounded file. Archive enumeration and marker
' checks belong only to the isolated worker while it owns export.lock.
Private Type PulseSystemTime
    Year As Integer
    Month As Integer
    DayOfWeek As Integer
    Day As Integer
    Hour As Integer
    Minute As Integer
    Second As Integer
    Milliseconds As Integer
End Type
Private Declare Sub GetSystemTime Lib "kernel32" (value As PulseSystemTime)
Private Declare Function CreateFileW Lib "kernel32" (ByVal name As Long, ByVal access As Long, ByVal sharing As Long, ByVal security As Long, ByVal disposition As Long, ByVal flags As Long, ByVal template As Long) As Long
Private Declare Function GetFileSize Lib "kernel32" (ByVal handle As Long, high As Long) As Long
Private Declare Function ReadFile Lib "kernel32" (ByVal handle As Long, buffer As Any, ByVal count As Long, actual As Long, ByVal overlapped As Long) As Long
Private Declare Function WriteFile Lib "kernel32" (ByVal handle As Long, buffer As Any, ByVal count As Long, actual As Long, ByVal overlapped As Long) As Long
Private Declare Function FlushFileBuffers Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function CloseHandle Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function MoveFileExW Lib "kernel32" (ByVal source As Long, ByVal destination As Long, ByVal flags As Long) As Long
Private Declare Function ReplaceFileW Lib "kernel32" (ByVal destination As Long, ByVal source As Long, ByVal backup As Long, ByVal flags As Long, ByVal exclude As Long, ByVal reserved As Long) As Long
Private Declare Function DeleteFileW Lib "kernel32" (ByVal name As Long) As Long
Private Declare Function GetCurrentProcessId Lib "kernel32" () As Long
Private Declare Function GetTickCount Lib "kernel32" () As Long
Private Const MAX_PULSE_BYTES As Long = 4096
Private Const PULSE_ERROR As Long = vbObjectError + 1850
Private mSerial As Long
Private mCrcTable(0 To 255) As Long
Private mCrcReady As Boolean

Public Function ExportPulseEpochValid(ByVal epoch As String) As Boolean
    If Len(epoch) < 1 Or Len(epoch) > 48 Then Exit Function
    If epoch Like "*[!A-Za-z0-9_-]*" Then Exit Function
    ExportPulseEpochValid = True
End Function

Private Function PulsePath(ByVal folder As String) As String
    If Len(folder) < 1 Or Len(folder) > 180 Or InStr(folder, vbNullChar) > 0 Then Err.Raise PULSE_ERROR, , "Invalid local pulse folder"
    If Right$(folder, 1) <> "\" Then folder = folder & "\"
    PulsePath = folder & "status.pulse"
End Function

Private Function PulseUtcNow(Optional ByVal includeMilliseconds As Boolean = True) As Date
    Dim value As PulseSystemTime
    GetSystemTime value
    PulseUtcNow = DateSerial(value.Year, value.Month, value.Day) + TimeSerial(value.Hour, value.Minute, value.Second)
    If includeMilliseconds Then PulseUtcNow = PulseUtcNow + CDbl(value.Milliseconds) / 86400000#
End Function

Private Function RightShift(ByVal value As Long) As Long
    RightShift = (value And &H7FFFFFFF) \ 2
    If (value And &H80000000) <> 0 Then RightShift = RightShift Or &H40000000
End Function

Private Function PulseCRC(ByVal value As String) As String
    Dim bytes() As Byte, i As Long, j As Long, c As Long
    If Not mCrcReady Then
        For i = 0 To 255
            c = i
            For j = 1 To 8
                If (c And 1) <> 0 Then c = RightShift(c) Xor &HEDB88320 Else c = RightShift(c)
            Next j
            mCrcTable(i) = c
        Next i
        mCrcReady = True
    End If
    bytes = value
    c = &HFFFFFFFF
    For i = 0 To UBound(bytes)
        j = c
        c = (c And &H7FFFFFFF) \ 256
        If j < 0 Then c = c Or &H800000
        c = c Xor mCrcTable((j Xor CLng(bytes(i))) And &HFF&)
    Next i
    PulseCRC = Right$("00000000" & Hex$(Not c), 8)
End Function

Private Function PackedPulse(ByVal body As String) As String
    PackedPulse = body & "CRC=" & PulseCRC(body) & vbCrLf
End Function

Private Function PulseNumber(ByVal value As String) As Long
    Dim magnitude As Double, i As Long, digit As Integer
    If Len(value) < 1 Or Len(value) > 10 Then Err.Raise PULSE_ERROR, , "Invalid pulse number length"
    If Len(value) > 1 And Left$(value, 1) = "0" Then Err.Raise PULSE_ERROR, , "Noncanonical pulse number"
    For i = 1 To Len(value)
        digit = AscW(Mid$(value, i, 1)) - 48
        If digit < 0 Or digit > 9 Then Err.Raise PULSE_ERROR, , "Invalid pulse number digit"
        magnitude = magnitude * 10# + digit
        If magnitude > 2147483647# Then Err.Raise PULSE_ERROR, , "Pulse number overflow"
    Next i
    PulseNumber = CLng(magnitude)
End Function

Private Function PulseTimestamp(ByVal value As String) As Date
    Dim timestamp As Date, digits As String
    If Len(value) <> 20 Then Err.Raise PULSE_ERROR, , "Invalid pulse UTC timestamp length"
    digits = Left$(value, 4) & Mid$(value, 6, 2) & Mid$(value, 9, 2) & Mid$(value, 12, 2) & Mid$(value, 15, 2) & Mid$(value, 18, 2)
    If digits Like "*[!0-9]*" Then Err.Raise PULSE_ERROR, , "Invalid pulse UTC timestamp digits"
    timestamp = DateSerial(CInt(Left$(value, 4)), CInt(Mid$(value, 6, 2)), CInt(Mid$(value, 9, 2))) + TimeSerial(CInt(Mid$(value, 12, 2)), CInt(Mid$(value, 15, 2)), CInt(Mid$(value, 18, 2)))
    If Format$(timestamp, "yyyy-mm-dd\Thh:nn:ss\Z") <> value Then Err.Raise PULSE_ERROR, , "Invalid pulse UTC timestamp"
    PulseTimestamp = timestamp
End Function

Private Function AtomicPulseWrite(ByVal folder As String, ByVal value As String, ByRef problem As String) As Boolean
    Dim path As String, temporary As String, handle As Long, bytes() As Byte, actual As Long, count As Long
    On Error GoTo Failed
    problem = ""
    path = PulsePath(folder)
    If LenB(value) < 2 Or LenB(value) > MAX_PULSE_BYTES Then Err.Raise PULSE_ERROR, , "Pulse write length is out of range"
    mSerial = (mSerial Mod 1000000) + 1
    temporary = path & ".tmp-" & Hex$(GetCurrentProcessId()) & "-" & Hex$(GetTickCount()) & "-" & CStr(mSerial)
    handle = CreateFileW(StrPtr(temporary), &H40000000, 0, 0, 1, &H80000080, 0)
    If handle = -1 Then Err.Raise PULSE_ERROR, , "Cannot create local pulse staging file"
    bytes = value
    count = UBound(bytes) + 1
    If WriteFile(handle, bytes(0), count, actual, 0) = 0 Or actual <> count Then Err.Raise PULSE_ERROR, , "Incomplete pulse staging write"
    If FlushFileBuffers(handle) = 0 Then Err.Raise PULSE_ERROR, , "Pulse staging flush failed"
    If CloseHandle(handle) = 0 Then Err.Raise PULSE_ERROR, , "Pulse staging close failed"
    handle = 0
    ' Replace an old complete snapshot only after the new snapshot is durable.
    If MoveFileExW(StrPtr(temporary), StrPtr(path), 9) = 0 Then
        ' ReplaceFile supports replacement of a snapshot held by a reader
        ' with delete sharing on Windows versions where MoveFileEx refuses it.
        If ReplaceFileW(StrPtr(path), StrPtr(temporary), 0, 0, 0, 0) = 0 Then Err.Raise PULSE_ERROR, , "Atomic local pulse replacement failed: Windows=" & CStr(Err.LastDllError)
    End If
    AtomicPulseWrite = True
    Exit Function
Failed:
    problem = "Export pulse write failed: " & Err.Description
    If handle <> 0 And handle <> -1 Then CloseHandle handle
    If Len(temporary) > 0 Then DeleteFileW StrPtr(temporary)
End Function

Public Function ExportWritePulse(ByVal folder As String, ByVal epoch As String, ByVal watermark As Long, ByVal pending As Long, ByVal uncertain As Long, ByRef problem As String) As Boolean
    Dim body As String
    On Error GoTo Failed
    problem = ""
    If Not ExportPulseEpochValid(epoch) Then Err.Raise PULSE_ERROR, , "Invalid export pulse epoch"
    If watermark < 0 Or pending < 0 Or uncertain < 0 Or uncertain > pending Then Err.Raise PULSE_ERROR, , "Invalid export pulse counts"
    body = "NILIT-EXPORT-PULSE-1" & vbCrLf & epoch & vbCrLf & CStr(watermark) & vbCrLf
    ' Format$ can round fractional seconds forward. Publish the sampled whole
    ' UTC second so our own freshly written pulse cannot appear in the future.
    body = body & CStr(pending) & vbCrLf & CStr(uncertain) & vbCrLf & Format$(PulseUtcNow(False), "yyyy-mm-dd\Thh:nn:ss\Z") & vbCrLf
    ExportWritePulse = AtomicPulseWrite(folder, PackedPulse(body), problem)
    Exit Function
Failed:
    problem = "Export pulse write failed: " & Err.Description
End Function

Public Function ExportInvalidatePulse(ByVal folder As String, ByRef problem As String) As Boolean
    ' Invalid archive/marker evidence must invalidate even a recent old zero.
    ExportInvalidatePulse = AtomicPulseWrite(folder, PackedPulse("NILIT-EXPORT-PULSE-UNAVAILABLE-1" & vbCrLf), problem)
End Function

Public Function ExportReadPulse(ByVal folder As String, ByVal expectedEpoch As String, ByVal requiredSequence As Long, ByVal maxAgeSeconds As Long, ByRef pending As Long, ByRef uncertain As Long, ByRef problem As String) As Boolean
    Dim path As String, handle As Long, size As Long, high As Long, actual As Long, bytes() As Byte
    Dim value As String, body As String, fields() As String, watermark As Long, ageSeconds As Double
    Dim readPending As Long, readUncertain As Long, atUtc As Date
    On Error GoTo Failed
    problem = ""
    pending = 0: uncertain = 0
    If Not ExportPulseEpochValid(expectedEpoch) Then Err.Raise PULSE_ERROR, , "Invalid expected pulse epoch"
    If requiredSequence < 0 Or maxAgeSeconds < 1 Or maxAgeSeconds > 86400 Then Err.Raise PULSE_ERROR, , "Invalid pulse freshness requirement"
    path = PulsePath(folder)
    ' Delete sharing permits the worker's rename; the opened handle continues
    ' reading one complete old/new snapshot without taking export.lock.
    handle = CreateFileW(StrPtr(path), &H80000000, 7, 0, 3, &H80, 0)
    If handle = -1 Then Err.Raise PULSE_ERROR, , "Local exporter pulse is missing or unreadable"
    size = GetFileSize(handle, high)
    If high <> 0 Or size < 2 Or size > MAX_PULSE_BYTES Or size Mod 2 <> 0 Then Err.Raise PULSE_ERROR, , "Invalid exporter pulse length"
    ReDim bytes(0 To size - 1)
    If ReadFile(handle, bytes(0), size, actual, 0) = 0 Or actual <> size Then Err.Raise PULSE_ERROR, , "Incomplete exporter pulse read"
    CloseHandle handle
    handle = 0
    value = bytes
    If Len(value) < 14 Then Err.Raise PULSE_ERROR, , "Truncated exporter pulse"
    body = Left$(value, Len(value) - 14)
    If PackedPulse(body) <> value Then Err.Raise PULSE_ERROR, , "Exporter pulse checksum mismatch"
    fields = Split(body, vbCrLf)
    If UBound(fields) <> 6 Then Err.Raise PULSE_ERROR, , "Invalid exporter pulse schema"
    If fields(0) <> "NILIT-EXPORT-PULSE-1" Or fields(6) <> "" Then Err.Raise PULSE_ERROR, , "Invalid exporter pulse schema"
    If StrComp(fields(1), expectedEpoch, vbBinaryCompare) <> 0 Then Err.Raise PULSE_ERROR, , "Exporter pulse epoch does not match"
    watermark = PulseNumber(fields(2))
    readPending = PulseNumber(fields(3))
    readUncertain = PulseNumber(fields(4))
    If readUncertain > readPending Then Err.Raise PULSE_ERROR, , "Exporter pulse uncertainty exceeds pending count"
    atUtc = PulseTimestamp(fields(5))
    ageSeconds = (CDbl(PulseUtcNow()) - CDbl(atUtc)) * 86400#
    If ageSeconds < 0# Then Err.Raise PULSE_ERROR, , "Exporter pulse UTC timestamp is in the future"
    If ageSeconds > CDbl(maxAgeSeconds) Then Err.Raise PULSE_ERROR, , "Exporter pulse is stale"
    If watermark < requiredSequence Then Err.Raise PULSE_ERROR, , "Exporter pulse has not observed the required event sequence"
    pending = readPending: uncertain = readUncertain
    ExportReadPulse = True
    Exit Function
Failed:
    problem = "Export pulse unavailable: " & Err.Description
    If handle <> 0 And handle <> -1 Then CloseHandle handle
End Function
