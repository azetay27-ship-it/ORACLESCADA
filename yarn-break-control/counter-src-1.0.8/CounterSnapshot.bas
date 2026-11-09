Attribute VB_Name = "CounterSnapshot"
Option Explicit

' Schema 1 is a strict, locale-independent binary record carried in a VB6
' Unicode String. StateStore preserves all UTF-16 code units including nulls.
' Unknown versions, record codes, duplicate heads, or trailing bytes fail.
' Candidate evidence and monotonic ticks are deliberately NOT persisted.
' Decode stages and validates every record before changing any caller state.

Private Declare Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" (destination As Any, source As Any, ByVal count As Long)
Private Const MAGIC_1 As Long = &H5354494E
Private Const MAGIC_2 As Long = &H3150414E
Private Const SNAPSHOT_VERSION As Long = 1
Private Const MAX_BYTES As Long = 1048574
Private Const MAX_TEXT_CHARS As Long = 4096
Private Const MAX_PENDING As Long = 8192
Private Const MAX_DURATION_MS As Double = 1E+15
Private Const SNAPSHOT_ERROR As Long = vbObjectError + 2741

Public Function SnapshotEncode(ByVal identity As String, ByVal epoch As String, ByVal nextSequence As Long, ByRef heads() As HeadState, ByRef pending() As QueuedEvent, ByVal pendingCount As Long, ByRef payload As String, ByRef problem As String) As Boolean
    Dim bytes() As Byte, position As Long
    Dim port As Integer, head As Integer, index As Long, previousSequence As Long
    Dim result As String
    On Error GoTo Invalid
    problem = ""
    ValidateArrays heads, pending
    ValidateIdentity identity
    ValidateEpoch epoch
    If nextSequence < 1 Then Reject "Next event sequence must be positive."
    If pendingCount < 0 Or pendingCount > MAX_PENDING Then Reject "Pending event count is out of range."
    ReDim bytes(0 To MAX_BYTES - 1)
    PutLong bytes, position, MAGIC_1
    PutLong bytes, position, MAGIC_2
    PutLong bytes, position, SNAPSHOT_VERSION
    PutLong bytes, position, 64
    PutLong bytes, position, pendingCount
    PutLong bytes, position, nextSequence
    PutText bytes, position, identity
    PutText bytes, position, epoch
    For port = 1 To 8
        For head = 1 To 8
            ValidateHead heads(port, head)
            PutInteger bytes, position, port
            PutInteger bytes, position, head
            PutHead bytes, position, heads(port, head)
        Next head
    Next port
    For index = 1 To pendingCount
        ValidateEvent pending(index), previousSequence, nextSequence
        PutEvent bytes, position, pending(index)
        previousSequence = pending(index).Sequence
    Next index
    result = String$(position \ 2, vbNullChar)
    CopyMemory ByVal StrPtr(result), bytes(0), position
    payload = result
    SnapshotEncode = True
    Exit Function
Invalid:
    problem = "Cannot encode snapshot: " & Err.Description
End Function

Public Function SnapshotDecode(ByVal expectedIdentity As String, ByVal payload As String, ByRef epoch As String, ByRef nextSequence As Long, ByRef heads() As HeadState, ByRef pending() As QueuedEvent, ByRef pendingCount As Long, ByRef problem As String) As Boolean
    Dim bytes() As Byte, position As Long, length As Long
    Dim loadedHeads(1 To 8, 1 To 8) As HeadState
    Dim loadedPending(1 To MAX_PENDING) As QueuedEvent
    Dim seen(1 To 8, 1 To 8) As Boolean
    Dim loadedCount As Long, loadedNext As Long, loadedEpoch As String, loadedIdentity As String
    Dim port As Integer, head As Integer, index As Long, previousSequence As Long
    On Error GoTo Invalid
    problem = ""
    ValidateArrays heads, pending
    ValidateIdentity expectedIdentity
    length = LenB(payload)
    If length < 32 Or length > MAX_BYTES Then Reject "Snapshot size is out of range."
    ReDim bytes(0 To length - 1)
    CopyMemory bytes(0), ByVal StrPtr(payload), length
    If TakeLong(bytes, position) <> MAGIC_1 Then Reject "Unknown snapshot signature."
    If TakeLong(bytes, position) <> MAGIC_2 Then Reject "Unknown snapshot signature."
    If TakeLong(bytes, position) <> SNAPSHOT_VERSION Then Reject "Unsupported snapshot version."
    If TakeLong(bytes, position) <> 64 Then Reject "Snapshot must contain exactly 64 heads."
    loadedCount = TakeLong(bytes, position)
    loadedNext = TakeLong(bytes, position)
    If loadedCount < 0 Or loadedCount > MAX_PENDING Then Reject "Pending event count is out of range."
    If loadedNext < 1 Then Reject "Next event sequence must be positive."
    loadedIdentity = TakeText(bytes, position)
    If StrComp(loadedIdentity, expectedIdentity, vbBinaryCompare) <> 0 Then Reject "Snapshot configuration identity does not match."
    loadedEpoch = TakeText(bytes, position)
    ValidateEpoch loadedEpoch
    For index = 1 To 64
        port = TakeInteger(bytes, position)
        head = TakeInteger(bytes, position)
        If port < 1 Or port > 8 Or head < 1 Or head > 8 Then Reject "Head key is out of range."
        If seen(port, head) Then Reject "Duplicate head key in snapshot."
        seen(port, head) = True
        TakeHead bytes, position, loadedHeads(port, head)
        ValidateHead loadedHeads(port, head)
    Next index
    For index = 1 To loadedCount
        TakeEvent bytes, position, loadedPending(index)
        ValidateEvent loadedPending(index), previousSequence, loadedNext
        previousSequence = loadedPending(index).Sequence
    Next index
    If position <> length Then Reject "Unexpected trailing snapshot fields or bytes."
    ' No caller output is touched before all format and business checks pass.
    For port = 1 To 8
        For head = 1 To 8
            heads(port, head) = loadedHeads(port, head)
        Next head
    Next port
    For index = 1 To MAX_PENDING
        pending(index) = loadedPending(index)
    Next index
    epoch = loadedEpoch
    nextSequence = loadedNext
    pendingCount = loadedCount
    SnapshotDecode = True
    Exit Function
Invalid:
    problem = "Cannot decode snapshot: " & Err.Description
End Function

Private Sub Reject(ByVal reason As String)
    Err.Raise SNAPSHOT_ERROR, "CounterSnapshot", reason
End Sub

Private Sub ValidateArrays(ByRef heads() As HeadState, ByRef pending() As QueuedEvent)
    Dim dimensionBound As Long, errorCode As Long
    If LBound(heads, 1) <> 1 Or UBound(heads, 1) <> 8 Or LBound(heads, 2) <> 1 Or UBound(heads, 2) <> 8 Then Reject "Head array must be (1 To 8, 1 To 8)."
    If LBound(pending, 1) <> 1 Or UBound(pending, 1) <> MAX_PENDING Then Reject "Pending array must be (1 To 8192)."
    On Error Resume Next
    dimensionBound = UBound(heads, 3)
    errorCode = Err.Number
    Err.Clear
    On Error GoTo 0
    If errorCode = 0 Then Reject "Head array must have exactly two dimensions."
    On Error Resume Next
    dimensionBound = UBound(pending, 2)
    errorCode = Err.Number
    Err.Clear
    On Error GoTo 0
    If errorCode = 0 Then Reject "Pending array must have exactly one dimension."
End Sub

Private Sub ValidateIdentity(ByVal identity As String)
    If Len(identity) = 0 Or Len(identity) > MAX_TEXT_CHARS Or InStr(identity, vbNullChar) <> 0 Then Reject "Configuration identity is empty, too long, or contains a null character."
End Sub

Private Sub ValidateEpoch(ByVal epoch As String)
    Dim value As String, index As Long, letter As String
    value = epoch
    If Len(value) = 38 Then
        If Left$(value, 1) <> "{" Or Right$(value, 1) <> "}" Then Reject "Invalid epoch GUID."
        value = Mid$(value, 2, 36)
    End If
    If Len(value) <> 36 Then Reject "Invalid epoch GUID length."
    For index = 1 To 36
        letter = Mid$(value, index, 1)
        If index = 9 Or index = 14 Or index = 19 Or index = 24 Then
            If letter <> "-" Then Reject "Invalid epoch GUID separator."
        Else
            If InStr(1, "0123456789abcdefABCDEF", letter, vbBinaryCompare) = 0 Then Reject "Invalid epoch GUID digit."
        End If
    Next index
End Sub

Private Function IsFinite(ByVal value As Double) As Boolean
    Dim parts(0 To 1) As Long
    CopyMemory parts(0), value, 8
    IsFinite = ((parts(1) And &H7FF00000) <> &H7FF00000)
End Function

Private Sub ValidateDateNumber(ByVal value As Double, ByVal allowEmpty As Boolean)
    If Not IsFinite(value) Then Reject "Nonfinite timestamp in snapshot."
    If allowEmpty And value = 0# Then Exit Sub
    If value < 2# Or value >= 2958466# Then Reject "Timestamp is outside supported years 1900 through 9999."
End Sub

Private Sub ValidateWipe(ByVal wipeDate As Long, ByVal wipeTime As Long)
    If wipeDate < 0 Or wipeDate > 31 Then Reject "Wiping day must be 0 through 31."
    If wipeTime < 0 Or wipeTime > 2359 Then Reject "Wiping time must be valid HHMM."
    If (wipeTime Mod 100) > 59 Then Reject "Wiping time minute must be 0 through 59."
End Sub

Private Sub ValidateHead(ByRef item As HeadState)
    If item.Initialized Then
        If item.Mode < 1 Or item.Mode > 4 Then Reject "Initialized head mode must be 1 through 4."
    Else
        If item.Mode <> 0 Then Reject "Uninitialized head mode must be zero."
    End If
    If Not IsFinite(item.ElapsedMs) Or Not IsFinite(item.StopMs) Then Reject "Nonfinite head duration."
    If item.ElapsedMs < 0# Or item.ElapsedMs > MAX_DURATION_MS Or item.StopMs < 0# Or item.StopMs > MAX_DURATION_MS Then Reject "Head duration is out of range."
    If item.WorkingWinding <> 0 And item.WorkingWinding <> 2 And item.WorkingWinding <> 4 And item.WorkingWinding <> 6 Then Reject "Working winding must be a masked 0, 2, 4, or 6."
    If item.Maintenance < 0 Or item.Maintenance > 5 Then Reject "Head maintenance code must be 0 through 5."
    If item.Blink < 0 Or item.Blink > 1 Then Reject "Head blink must be 0 or 1."
    ValidateWipe item.WipingDate, item.WipingTime
    ValidateDateNumber CDbl(item.LastObservationUtc), True
    ValidateDateNumber CDbl(item.GapStartUtc), True
End Sub

Private Function EventKindCode(ByVal kind As String) As Integer
    Select Case kind
        Case "start": EventKindCode = 1
        Case "finish": EventKindCode = 2
        Case "blue-previous": EventKindCode = 3
        Case "maintenance": EventKindCode = 4
        Case "auto": EventKindCode = 5
        Case Else: Reject "Unknown event kind."
    End Select
End Function

Private Function EventKindText(ByVal kind As Integer) As String
    Select Case kind
        Case 1: EventKindText = "start"
        Case 2: EventKindText = "finish"
        Case 3: EventKindText = "blue-previous"
        Case 4: EventKindText = "maintenance"
        Case 5: EventKindText = "auto"
        Case Else: Reject "Unknown event kind code."
    End Select
End Function

Private Sub ValidateEvent(ByRef item As QueuedEvent, ByVal previousSequence As Long, ByVal nextSequence As Long)
    Dim kindCode As Integer
    If item.Sequence <= previousSequence Or item.Sequence >= nextSequence Then Reject "Event sequences must increase and be below next sequence."
    If item.Port < 1 Or item.Port > 8 Or item.Head < 1 Or item.Head > 8 Then Reject "Event head key is out of range."
    kindCode = EventKindCode(item.Kind)
    If item.Mode < 1 Or item.Mode > 5 Then Reject "Event mode is out of range."
    If item.Kind = "auto" Then
        If item.Mode <> 5 Then Reject "Auto event must use mode 5."
    Else
        If item.Mode > 4 Then Reject "Color event mode must be 1 through 4."
    End If
    If item.Kind = "maintenance" And item.Mode <> 4 Then Reject "Maintenance event must use mode 4."
    If item.Maintenance < 0 Or item.Maintenance > 5 Then Reject "Event maintenance code must be 0 through 5."
    If item.Minutes < 0 Then Reject "Event minutes must be nonnegative."
    ValidateDateNumber CDbl(item.OccurredLocal), False
    ValidateWipe item.WipingDate, item.WipingTime
End Sub

Private Sub PutHead(ByRef bytes() As Byte, ByRef position As Long, ByRef item As HeadState)
    PutBoolean bytes, position, item.Initialized
    PutInteger bytes, position, item.Mode
    PutDouble bytes, position, item.ElapsedMs
    PutDouble bytes, position, item.StopMs
    PutLong bytes, position, item.WorkingWinding
    PutLong bytes, position, item.Maintenance
    PutLong bytes, position, item.WipingDate
    PutLong bytes, position, item.WipingTime
    PutInteger bytes, position, item.Blink
    PutDouble bytes, position, CDbl(item.LastObservationUtc)
    PutDouble bytes, position, CDbl(item.GapStartUtc)
    PutBoolean bytes, position, item.GapOpen
    PutBoolean bytes, position, item.HasGap
    PutBoolean bytes, position, item.PendingMaintenanceClear
    PutBoolean bytes, position, item.GapBeforePending
End Sub

Private Sub TakeHead(ByRef bytes() As Byte, ByRef position As Long, ByRef item As HeadState)
    item.Initialized = TakeBoolean(bytes, position)
    item.Mode = TakeInteger(bytes, position)
    item.ElapsedMs = TakeDouble(bytes, position)
    item.StopMs = TakeDouble(bytes, position)
    item.WorkingWinding = TakeLong(bytes, position)
    item.Maintenance = TakeLong(bytes, position)
    item.WipingDate = TakeLong(bytes, position)
    item.WipingTime = TakeLong(bytes, position)
    item.Blink = TakeInteger(bytes, position)
    item.LastObservationUtc = TakeDate(bytes, position, True)
    item.GapStartUtc = TakeDate(bytes, position, True)
    item.GapOpen = TakeBoolean(bytes, position)
    item.HasGap = TakeBoolean(bytes, position)
    item.PendingMaintenanceClear = TakeBoolean(bytes, position)
    item.GapBeforePending = TakeBoolean(bytes, position)
    item.HasBaseline = False
    item.LastTickMs = 0#
    item.LastSampleMode = 0
    item.CandidateMode = 0
    item.CandidateCount = 0
    item.NeedsPublish = True
End Sub

Private Sub PutEvent(ByRef bytes() As Byte, ByRef position As Long, ByRef item As QueuedEvent)
    PutLong bytes, position, item.Sequence
    PutInteger bytes, position, item.Port
    PutInteger bytes, position, item.Head
    PutInteger bytes, position, EventKindCode(item.Kind)
    PutInteger bytes, position, item.Mode
    PutLong bytes, position, item.Maintenance
    PutLong bytes, position, item.Minutes
    PutDouble bytes, position, CDbl(item.OccurredLocal)
    PutBoolean bytes, position, item.HasGap
    PutLong bytes, position, item.WipingDate
    PutLong bytes, position, item.WipingTime
End Sub

Private Sub TakeEvent(ByRef bytes() As Byte, ByRef position As Long, ByRef item As QueuedEvent)
    item.Sequence = TakeLong(bytes, position)
    item.Port = TakeInteger(bytes, position)
    item.Head = TakeInteger(bytes, position)
    item.Kind = EventKindText(TakeInteger(bytes, position))
    item.Mode = TakeInteger(bytes, position)
    item.Maintenance = TakeLong(bytes, position)
    item.Minutes = TakeLong(bytes, position)
    item.OccurredLocal = TakeDate(bytes, position, False)
    item.HasGap = TakeBoolean(bytes, position)
    item.WipingDate = TakeLong(bytes, position)
    item.WipingTime = TakeLong(bytes, position)
End Sub

Private Sub NeedBytes(ByRef bytes() As Byte, ByVal position As Long, ByVal count As Long)
    If position < 0 Or count < 0 Then Reject "Invalid snapshot byte position."
    If count > UBound(bytes) - position + 1 Then Reject "Truncated snapshot or payload limit exceeded."
End Sub

Private Sub PutInteger(ByRef bytes() As Byte, ByRef position As Long, ByVal value As Integer)
    NeedBytes bytes, position, 2
    CopyMemory bytes(position), value, 2
    position = position + 2
End Sub

Private Function TakeInteger(ByRef bytes() As Byte, ByRef position As Long) As Integer
    NeedBytes bytes, position, 2
    CopyMemory TakeInteger, bytes(position), 2
    position = position + 2
End Function

Private Sub PutLong(ByRef bytes() As Byte, ByRef position As Long, ByVal value As Long)
    NeedBytes bytes, position, 4
    CopyMemory bytes(position), value, 4
    position = position + 4
End Sub

Private Function TakeLong(ByRef bytes() As Byte, ByRef position As Long) As Long
    NeedBytes bytes, position, 4
    CopyMemory TakeLong, bytes(position), 4
    position = position + 4
End Function

Private Sub PutDouble(ByRef bytes() As Byte, ByRef position As Long, ByVal value As Double)
    NeedBytes bytes, position, 8
    CopyMemory bytes(position), value, 8
    position = position + 8
End Sub

Private Function TakeDouble(ByRef bytes() As Byte, ByRef position As Long) As Double
    NeedBytes bytes, position, 8
    CopyMemory TakeDouble, bytes(position), 8
    position = position + 8
End Function

Private Function TakeDate(ByRef bytes() As Byte, ByRef position As Long, ByVal allowEmpty As Boolean) As Date
    Dim value As Double
    value = TakeDouble(bytes, position)
    ValidateDateNumber value, allowEmpty
    TakeDate = CDate(value)
End Function

Private Sub PutBoolean(ByRef bytes() As Byte, ByRef position As Long, ByVal value As Boolean)
    If value Then
        PutInteger bytes, position, 1
    Else
        PutInteger bytes, position, 0
    End If
End Sub

Private Function TakeBoolean(ByRef bytes() As Byte, ByRef position As Long) As Boolean
    Dim value As Integer
    value = TakeInteger(bytes, position)
    If value <> 0 And value <> 1 Then Reject "Unknown Boolean representation."
    TakeBoolean = (value = 1)
End Function

Private Sub PutText(ByRef bytes() As Byte, ByRef position As Long, ByVal value As String)
    PutLong bytes, position, Len(value)
    NeedBytes bytes, position, LenB(value)
    If LenB(value) > 0 Then CopyMemory bytes(position), ByVal StrPtr(value), LenB(value)
    position = position + LenB(value)
End Sub

Private Function TakeText(ByRef bytes() As Byte, ByRef position As Long) As String
    Dim length As Long, result As String
    length = TakeLong(bytes, position)
    If length < 0 Or length > MAX_TEXT_CHARS Then Reject "Snapshot text length is out of range."
    NeedBytes bytes, position, length * 2
    result = String$(length, vbNullChar)
    If length > 0 Then CopyMemory ByVal StrPtr(result), bytes(position), length * 2
    position = position + length * 2
    TakeText = result
End Function
