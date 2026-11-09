Attribute VB_Name = "StateStore"
Option Explicit

' Native 32-bit VB6 / Windows 7+. No COM, .NET, or network dependency.
' StoreOpen owns state.lock exclusively until StoreClose. Always call StoreLoad
' before StoreSave; only 0 (new) or 1 (valid) enables saves. A failure does not
' alter the caller's payload. Slot files are never repaired during load.
' Envelope v1: eight little-endian Longs (32 bytes), then UTF-16LE bytes.
' Fields: magic1, magic2, version, sequence, byte length, reserved=0, CRC32,
' trailer. CRC32 covers the entire envelope with its CRC field set to zero.
' A save flushes a same-directory temporary file before one write-through
' rename. The other committed slot remains untouched if any save step fails.
' Hardware/storage must honor Windows flush requests for power-loss durability.

Private Declare Function CreateFileW Lib "kernel32" (ByVal name As Long, ByVal access As Long, ByVal sharing As Long, ByVal security As Long, ByVal disposition As Long, ByVal flags As Long, ByVal template As Long) As Long
Private Declare Function CreateDirectoryW Lib "kernel32" (ByVal name As Long, ByVal security As Long) As Long
Private Declare Function GetFullPathNameW Lib "kernel32" (ByVal name As Long, ByVal capacity As Long, ByVal buffer As Long, ByVal filePart As Long) As Long
Private Declare Function GetFileAttributesW Lib "kernel32" (ByVal name As Long) As Long
Private Declare Function GetFileSize Lib "kernel32" (ByVal handle As Long, high As Long) As Long
Private Declare Function ReadFile Lib "kernel32" (ByVal handle As Long, buffer As Any, ByVal count As Long, actual As Long, ByVal overlapped As Long) As Long
Private Declare Function WriteFile Lib "kernel32" (ByVal handle As Long, buffer As Any, ByVal count As Long, actual As Long, ByVal overlapped As Long) As Long
Private Declare Function FlushFileBuffers Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function CloseHandle Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function MoveFileExW Lib "kernel32" (ByVal source As Long, ByVal destination As Long, ByVal flags As Long) As Long
Private Declare Sub CopyMemory Lib "kernel32" Alias "RtlMoveMemory" (destination As Any, source As Any, ByVal count As Long)

Private Const GENERIC_READ As Long = &H80000000
Private Const GENERIC_WRITE As Long = &H40000000
Private Const OPEN_EXISTING As Long = 3
Private Const OPEN_ALWAYS As Long = 4
Private Const CREATE_ALWAYS As Long = 2
Private Const FILE_ATTRIBUTE_NORMAL As Long = &H80
Private Const FILE_ATTRIBUTE_DIRECTORY As Long = &H10
Private Const FILE_FLAG_WRITE_THROUGH As Long = &H80000000
Private Const MOVEFILE_REPLACE_EXISTING As Long = 1
Private Const MOVEFILE_WRITE_THROUGH As Long = 8
Private Const ERROR_FILE_NOT_FOUND As Long = 2
Private Const ERROR_PATH_NOT_FOUND As Long = 3
Private Const HEADER_BYTES As Long = 32
Private Const MAX_PAYLOAD_BYTES As Long = 1048576
Private Const MAGIC_1 As Long = &H494C494E
Private Const MAGIC_2 As Long = &H3154534C
Private Const TRAILER As Long = &H454E4F44

Private Type StoreHeader
    magic1 As Long
    magic2 As Long
    version As Long
    sequence As Long
    payloadBytes As Long
    reserved As Long
    checksum As Long
    endMarker As Long
End Type

Private mLock As Long
Private mFolder As String
Private mLoaded As Boolean
Private mSequence As Long
Private mCurrentSlot As Integer
Private mCrcTable(0 To 255) As Long
Private mCrcReady As Boolean

Public Function StoreOpen(ByVal folder As String, ByRef problem As String) As Boolean
    Dim fullPath As String, count As Long, attributes As Long
    Dim lockPath As String, code As Long
    On Error GoTo Unexpected
    problem = ""
    If mLock <> 0 Then
        problem = "State store is already open in this process."
        Exit Function
    End If
    If Len(folder) = 0 Or InStr(folder, vbNullChar) <> 0 Then
        problem = "A nonempty state folder without null characters is required."
        Exit Function
    End If
    fullPath = String$(260, vbNullChar)
    count = GetFullPathNameW(StrPtr(folder), Len(fullPath), StrPtr(fullPath), 0)
    If count = 0 Then
        problem = "Cannot resolve state folder; Windows error " & CStr(Err.LastDllError) & "."
        Exit Function
    End If
    If count > 220 Then
        problem = "State folder path is too long (maximum 220 characters)."
        Exit Function
    End If
    fullPath = Left$(fullPath, count)
    attributes = GetFileAttributesW(StrPtr(fullPath))
    If attributes = -1 Then
        code = Err.LastDllError
        If code <> ERROR_FILE_NOT_FOUND And code <> ERROR_PATH_NOT_FOUND Then
            problem = "Cannot inspect state folder; Windows error " & CStr(code) & "."
            Exit Function
        End If
        If CreateDirectoryW(StrPtr(fullPath), 0) = 0 Then
            code = Err.LastDllError
            ' A competing instance may have just created the directory.
            attributes = GetFileAttributesW(StrPtr(fullPath))
            If attributes = -1 Then
                problem = "Cannot create state folder; Windows error " & CStr(code) & "."
                Exit Function
            End If
        Else
            attributes = FILE_ATTRIBUTE_DIRECTORY
        End If
    End If
    If (attributes And FILE_ATTRIBUTE_DIRECTORY) = 0 Then
        problem = "State folder path names a file."
        Exit Function
    End If
    If Right$(fullPath, 1) <> "\" Then fullPath = fullPath & "\"
    lockPath = fullPath & "state.lock"
    mLock = CreateFileW(StrPtr(lockPath), GENERIC_READ Or GENERIC_WRITE, 0, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0)
    If mLock = -1 Then
        code = Err.LastDllError
        mLock = 0
        problem = "Cannot exclusively lock state folder (another instance or access failure); Windows error " & CStr(code) & "."
        Exit Function
    End If
    mFolder = fullPath
    mLoaded = False
    mSequence = 0
    mCurrentSlot = 0
    StoreOpen = True
    Exit Function
Unexpected:
    problem = "State open failed: " & CStr(Err.Number) & " / " & Err.Description
    StoreClose
End Function

Public Sub StoreClose()
    If mLock <> 0 Then CloseHandle mLock
    mLock = 0
    mFolder = ""
    mLoaded = False
    mSequence = 0
    mCurrentSlot = 0
End Sub

Public Function StoreLoad(ByRef payload As String, ByRef problem As String) As Integer
    Dim aStatus As Integer, bStatus As Integer, tempStatus As Integer
    Dim aSequence As Long, bSequence As Long
    Dim aPayload As String, bPayload As String
    Dim aProblem As String, bProblem As String, tempProblem As String
    On Error GoTo Unexpected
    StoreLoad = -1
    problem = ""
    mLoaded = False
    If mLock = 0 Then
        problem = "State store is not open."
        Exit Function
    End If
    aStatus = ReadSlot(mFolder & "state-a.bin", aSequence, aPayload, aProblem)
    bStatus = ReadSlot(mFolder & "state-b.bin", bSequence, bPayload, bProblem)
    tempStatus = PathStatus(mFolder & "state-pending.tmp", tempProblem)
    If aStatus < -1 Or bStatus < -1 Or tempStatus = -1 Then
        problem = "State load refused: " & aProblem & " " & bProblem & " " & tempProblem
        Exit Function
    End If
    If aStatus = 0 And bStatus = 0 Then
        If tempStatus <> 0 Then
            problem = "No committed state, but an interrupted-save temporary file exists. Preserve files for review."
            Exit Function
        End If
        mSequence = 0
        mCurrentSlot = 0
        mLoaded = True
        payload = ""
        StoreLoad = 0
        Exit Function
    End If
    If aStatus <> 1 And bStatus <> 1 Then
        problem = "No valid state slot. Preserve files for review. " & aProblem & " " & bProblem
        Exit Function
    End If
    If aStatus = 1 And bStatus = 1 Then
        If aSequence = bSequence Then
            If StrComp(aPayload, bPayload, vbBinaryCompare) <> 0 Then
                problem = "State slots have the same sequence but different payloads. Preserve files for review."
                Exit Function
            End If
        End If
    End If
    If aStatus = 1 And (bStatus <> 1 Or aSequence >= bSequence) Then
        payload = aPayload
        mSequence = aSequence
        mCurrentSlot = 1
    Else
        payload = bPayload
        mSequence = bSequence
        mCurrentSlot = 2
    End If
    If aStatus = -1 Or bStatus = -1 Then
        problem = "Recovered valid committed state; another slot is corrupt or truncated. " & aProblem & " " & bProblem
    End If
    If mSequence > 1 And (aStatus = 0 Or bStatus = 0) Then
        problem = "Recovered the only available committed state; a previously expected slot is missing."
    End If
    If tempStatus = 1 Then
        If Len(problem) > 0 Then problem = problem & " "
        problem = problem & "An interrupted-save temporary file was ignored; committed state was loaded."
    End If
    mLoaded = True
    StoreLoad = 1
    Exit Function
Unexpected:
    problem = "State load failed: " & CStr(Err.Number) & " / " & Err.Description
    mLoaded = False
End Function

Public Function StoreSave(ByVal payload As String, ByRef problem As String) As Boolean
    Dim header As StoreHeader, bytes() As Byte
    Dim payloadSize As Long, total As Long, offset As Long, actual As Long
    Dim handle As Long, pending As String, target As String, targetSlot As Integer
    Dim code As Long
    On Error GoTo Unexpected
    problem = ""
    If mLock = 0 Or Not mLoaded Then
        problem = "Open and successfully load the state store before saving."
        Exit Function
    End If
    If Len(payload) > MAX_PAYLOAD_BYTES \ 2 Then
        problem = "State payload exceeds the 1 MiB limit."
        Exit Function
    End If
    If mSequence = &H7FFFFFFF Then
        problem = "State sequence is exhausted; preserve files for review."
        Exit Function
    End If
    payloadSize = LenB(payload)
    total = HEADER_BYTES + payloadSize
    ReDim bytes(0 To total - 1)
    header.magic1 = MAGIC_1
    header.magic2 = MAGIC_2
    header.version = 1
    header.sequence = mSequence + 1
    header.payloadBytes = payloadSize
    header.endMarker = TRAILER
    CopyMemory bytes(0), header, HEADER_BYTES
    If payloadSize > 0 Then CopyMemory bytes(HEADER_BYTES), ByVal StrPtr(payload), payloadSize
    header.checksum = CalculateCrc(bytes, total)
    CopyMemory bytes(0), header, HEADER_BYTES
    pending = mFolder & "state-pending.tmp"
    If mCurrentSlot = 1 Then
        target = mFolder & "state-b.bin"
        targetSlot = 2
    Else
        target = mFolder & "state-a.bin"
        targetSlot = 1
    End If
    handle = CreateFileW(StrPtr(pending), GENERIC_WRITE, 0, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL Or FILE_FLAG_WRITE_THROUGH, 0)
    If handle = -1 Then
        code = Err.LastDllError
        handle = 0
        problem = "Cannot create temporary state file; Windows error " & CStr(code) & "."
        Exit Function
    End If
    Do While offset < total
        If WriteFile(handle, bytes(offset), total - offset, actual, 0) = 0 Then
            code = Err.LastDllError
            problem = "State write failed; Windows error " & CStr(code) & "."
            GoTo Failed
        End If
        If actual <= 0 Then
            problem = "State write made no progress."
            GoTo Failed
        End If
        offset = offset + actual
    Loop
    If FlushFileBuffers(handle) = 0 Then
        problem = "State flush failed; Windows error " & CStr(Err.LastDllError) & "."
        GoTo Failed
    End If
    If CloseHandle(handle) = 0 Then
        problem = "State temporary file close failed; Windows error " & CStr(Err.LastDllError) & "."
        handle = 0
        Exit Function
    End If
    handle = 0
    If MoveFileExW(StrPtr(pending), StrPtr(target), MOVEFILE_REPLACE_EXISTING Or MOVEFILE_WRITE_THROUGH) = 0 Then
        problem = "State commit failed; previous committed slot is retained; Windows error " & CStr(Err.LastDllError) & "."
        Exit Function
    End If
    mSequence = header.sequence
    mCurrentSlot = targetSlot
    StoreSave = True
    Exit Function
Unexpected:
    problem = "State save failed: " & CStr(Err.Number) & " / " & Err.Description
Failed:
    If handle <> 0 Then CloseHandle handle
End Function

' 0 missing, 1 exists, -1 I/O failure. Directories count as existing evidence.
Private Function PathStatus(ByVal path As String, ByRef problem As String) As Integer
    Dim attributes As Long, code As Long
    attributes = GetFileAttributesW(StrPtr(path))
    If attributes <> -1 Then
        PathStatus = 1
    Else
        code = Err.LastDllError
        If code = ERROR_FILE_NOT_FOUND Or code = ERROR_PATH_NOT_FOUND Then
            PathStatus = 0
        Else
            PathStatus = -1
            problem = "Cannot inspect " & path & "; Windows error " & CStr(code) & "."
        End If
    End If
End Function

' 0 absent, 1 valid, -1 corrupt, -2 I/O failure, -3 incompatible envelope.
Private Function ReadSlot(ByVal path As String, ByRef sequence As Long, ByRef payload As String, ByRef problem As String) As Integer
    Dim status As Integer, handle As Long, code As Long
    Dim size As Long, high As Long, offset As Long, actual As Long
    Dim bytes() As Byte, header As StoreHeader, expected As Long
    On Error GoTo Unexpected
    status = PathStatus(path, problem)
    If status = 0 Then Exit Function
    ReadSlot = -2
    If status < 0 Then Exit Function
    handle = CreateFileW(StrPtr(path), GENERIC_READ, 1, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0)
    If handle = -1 Then
        code = Err.LastDllError
        handle = 0
        problem = "Cannot read " & path & "; Windows error " & CStr(code) & "."
        Exit Function
    End If
    size = GetFileSize(handle, high)
    If size = -1 Then
        problem = "Cannot measure " & path & "; Windows error " & CStr(Err.LastDllError) & "."
        GoTo Finished
    End If
    ReadSlot = -1
    If high <> 0 Or size < HEADER_BYTES Or size > HEADER_BYTES + MAX_PAYLOAD_BYTES Then
        problem = "Invalid state file size: " & path & "."
        GoTo Finished
    End If
    ReDim bytes(0 To size - 1)
    Do While offset < size
        If ReadFile(handle, bytes(offset), size - offset, actual, 0) = 0 Then
            ReadSlot = -2
            problem = "Cannot read " & path & "; Windows error " & CStr(Err.LastDllError) & "."
            GoTo Finished
        End If
        If actual <= 0 Then
            problem = "Truncated state file: " & path & "."
            GoTo Finished
        End If
        offset = offset + actual
    Loop
    CopyMemory header, bytes(0), HEADER_BYTES
    If header.magic1 <> MAGIC_1 Or header.magic2 <> MAGIC_2 Then
        problem = "Invalid state signature: " & path & "."
        GoTo Finished
    End If
    If header.version <> 1 Then
        ReadSlot = -3
        problem = "Unsupported state envelope version: " & path & "."
        GoTo Finished
    End If
    If header.payloadBytes < 0 Or header.payloadBytes > MAX_PAYLOAD_BYTES Then
        problem = "Invalid state payload length: " & path & "."
        GoTo Finished
    End If
    If header.sequence < 1 Or header.reserved <> 0 Or header.endMarker <> TRAILER Or (header.payloadBytes Mod 2) <> 0 Or header.payloadBytes <> size - HEADER_BYTES Then
        problem = "Invalid state header or length: " & path & "."
        GoTo Finished
    End If
    expected = header.checksum
    header.checksum = 0
    CopyMemory bytes(0), header, HEADER_BYTES
    If CalculateCrc(bytes, size) <> expected Then
        problem = "State checksum mismatch: " & path & "."
        GoTo Finished
    End If
    payload = String$(header.payloadBytes \ 2, vbNullChar)
    If header.payloadBytes > 0 Then CopyMemory ByVal StrPtr(payload), bytes(HEADER_BYTES), header.payloadBytes
    sequence = header.sequence
    ReadSlot = 1
Finished:
    If handle <> 0 Then CloseHandle handle
    Exit Function
Unexpected:
    problem = "State slot read failed: " & CStr(Err.Number) & " / " & Err.Description
    ReadSlot = -2
    If handle <> 0 Then CloseHandle handle
End Function

Private Function ShiftRightOne(ByVal value As Long) As Long
    ShiftRightOne = (value And &H7FFFFFFF) \ 2
    If value < 0 Then ShiftRightOne = ShiftRightOne Or &H40000000
End Function

Private Function CalculateCrc(ByRef bytes() As Byte, ByVal count As Long) As Long
    Dim index As Long, bit As Long, value As Long, crc As Long
    If Not mCrcReady Then
        For index = 0 To 255
            value = index
            For bit = 1 To 8
                If (value And 1) <> 0 Then
                    value = ShiftRightOne(value) Xor &HEDB88320
                Else
                    value = ShiftRightOne(value)
                End If
            Next bit
            mCrcTable(index) = value
        Next index
        mCrcReady = True
    End If
    crc = &HFFFFFFFF
    For index = 0 To count - 1
        value = (crc And &H7FFFFFFF) \ &H100
        If crc < 0 Then value = value Or &H800000
        crc = value Xor mCrcTable((crc Xor CLng(bytes(index))) And &HFF&)
    Next index
    CalculateCrc = Not crc
End Function
