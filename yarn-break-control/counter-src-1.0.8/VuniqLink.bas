Attribute VB_Name = "VuniqLink"
Option Explicit

' These calls observe the Vuniq API. They do not prove per-item serial freshness.
' Calls are synchronous and can block; the external watchdog bounds NILIT.
Private Const CONNECTOR_CLSID As String = "{33B13A42-BAF1-4543-96DE-DF12FE54DB2D}"
Private Const HKEY_CLASSES_ROOT As Long = &H80000000
Private Const KEY_READ_32 As Long = &H20219
Private Const REG_SZ As Long = 1
Private Const ERROR_FILE_NOT_FOUND As Long = 2
Private Const ERROR_PATH_NOT_FOUND As Long = 3
Private Const TH32CS_SNAPPROCESS As Long = 2
Private Const PROCESS_QUERY_LIMITED_INFORMATION As Long = &H1000
Private Const INVALID_HANDLE_VALUE As Long = -1

Private Type FILETIME
    Low As Long
    High As Long
End Type

Private Type PROCESSENTRY32
    Size As Long
    Usage As Long
    ProcessId As Long
    DefaultHeap As Long
    ModuleId As Long
    Threads As Long
    ParentProcessId As Long
    BasePriority As Long
    Flags As Long
    ExeFile As String * 260
End Type

Private Declare Function RegOpenKeyEx Lib "advapi32.dll" Alias "RegOpenKeyExA" (ByVal key As Long, ByVal subkey As String, ByVal options As Long, ByVal access As Long, ByRef result As Long) As Long
Private Declare Function RegQueryValueEx Lib "advapi32.dll" Alias "RegQueryValueExA" (ByVal key As Long, ByVal name As String, ByVal reserved As Long, ByRef kind As Long, ByVal data As String, ByRef size As Long) As Long
Private Declare Function RegCloseKey Lib "advapi32.dll" (ByVal key As Long) As Long
Private Declare Function CreateToolhelp32Snapshot Lib "kernel32" (ByVal flags As Long, ByVal processId As Long) As Long
Private Declare Function Process32First Lib "kernel32" (ByVal snapshot As Long, ByRef entry As PROCESSENTRY32) As Long
Private Declare Function Process32Next Lib "kernel32" (ByVal snapshot As Long, ByRef entry As PROCESSENTRY32) As Long
Private Declare Function OpenProcess Lib "kernel32" (ByVal access As Long, ByVal inherit As Long, ByVal processId As Long) As Long
Private Declare Function GetProcessTimes Lib "kernel32" (ByVal process As Long, ByRef created As FILETIME, ByRef exited As FILETIME, ByRef kernel As FILETIME, ByRef user As FILETIME) As Long
Private Declare Function QueryFullProcessImageName Lib "kernel32" Alias "QueryFullProcessImageNameW" (ByVal process As Long, ByVal flags As Long, ByVal name As Long, ByRef size As Long) As Long
Private Declare Function ProcessIdToSessionId Lib "kernel32" (ByVal processId As Long, ByRef session As Long) As Long
Private Declare Function GetCurrentProcessId Lib "kernel32" () As Long
Private Declare Function CloseHandle Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function GetFullPathName Lib "kernel32" Alias "GetFullPathNameW" (ByVal path As Long, ByVal capacity As Long, ByVal output As Long, ByVal filePart As Long) As Long
Private Declare Function GetLongPathName Lib "kernel32" Alias "GetLongPathNameW" (ByVal shortName As Long, ByVal longName As Long, ByVal capacity As Long) As Long

Private mConnector As Object
Private mExpectedExe As String
Private mIdentity As String
Private mCommSupported(1 To 8) As Boolean
Private mCommEverSupported(1 To 8) As Boolean
Private mRetryPublished(1 To 8, 1 To 8) As Boolean

Private Sub Reject(ByVal message As String)
    Err.Raise vbObjectError + 2301, "VuniqLink", message
End Sub

Private Function Failure(ByVal operation As String) As String
    Failure = operation & ": " & Err.Description & " (HRESULT 0x" & Right$("00000000" & Hex$(Err.Number), 8) & ")"
End Function

Private Function StripPadding(ByVal value As String) As String
    Dim last As Long, ch As String
    last = Len(value)
    Do While last > 0
        ch = Mid$(value, last, 1)
        If ch <> " " And ch <> vbNullChar Then Exit Do
        last = last - 1
    Loop
    StripPadding = Left$(value, last)
End Function

Private Function CanonicalPath(ByVal path As String) As String
    Dim buffer As String, count As Long
    If Len(path) < 4 Or Len(path) > 2048 Then Reject "Invalid executable path length"
    If Mid$(path, 2, 2) <> ":\" Then Reject "An absolute local executable path is required"
    If InStr(3, path, ":", vbBinaryCompare) <> 0 Or InStr(path, vbNullChar) <> 0 Then Reject "Invalid executable path"
    buffer = String$(32768, vbNullChar)
    count = GetFullPathName(StrPtr(path), Len(buffer), StrPtr(buffer), 0)
    If count = 0 Or count >= Len(buffer) Then Reject "Cannot resolve executable path"
    path = Left$(buffer, count)
    buffer = String$(32768, vbNullChar)
    count = GetLongPathName(StrPtr(path), StrPtr(buffer), Len(buffer))
    If count = 0 Or count >= Len(buffer) Then Reject "Cannot resolve existing executable path"
    CanonicalPath = Left$(buffer, count)
End Function

Private Function RegistryText(ByVal subkey As String, ByVal name As String, ByRef found As Boolean) As String
    Dim key As Long, result As Long, kind As Long, count As Long, buffer As String
    Dim savedNumber As Long, savedDescription As String
    On Error GoTo Failed
    found = False
    result = RegOpenKeyEx(HKEY_CLASSES_ROOT, subkey, 0, KEY_READ_32, key)
    If result = ERROR_FILE_NOT_FOUND Or result = ERROR_PATH_NOT_FOUND Then Exit Function
    If result <> 0 Then Reject "Cannot read 32-bit COM registration (Windows " & CStr(result) & ")"
    count = 8192
    buffer = String$(count, vbNullChar)
    result = RegQueryValueEx(key, name, 0, kind, buffer, count)
    If result <> ERROR_FILE_NOT_FOUND And result <> ERROR_PATH_NOT_FOUND Then
        If result <> 0 Then Reject "Cannot read COM registration value (Windows " & CStr(result) & ")"
        If kind <> REG_SZ Or count < 1 Or count > Len(buffer) Then Reject "COM registration must contain plain text"
        buffer = Left$(buffer, count)
        If Right$(buffer, 1) = vbNullChar Then buffer = Left$(buffer, Len(buffer) - 1)
        If InStr(buffer, vbNullChar) <> 0 Then Reject "Malformed COM registration text"
        found = True
        RegistryText = buffer
    End If
    RegCloseKey key
    Exit Function
Failed:
    savedNumber = Err.Number: savedDescription = Err.Description
    If key <> 0 Then RegCloseKey key
    Err.Raise savedNumber, "VuniqLink", savedDescription
End Function

Private Function RegistryKeyExists(ByVal subkey As String) As Boolean
    Dim key As Long, result As Long
    result = RegOpenKeyEx(HKEY_CLASSES_ROOT, subkey, 0, KEY_READ_32, key)
    If result = ERROR_FILE_NOT_FOUND Or result = ERROR_PATH_NOT_FOUND Then Exit Function
    If result <> 0 Then Reject "Cannot inspect COM registration (Windows " & CStr(result) & ")"
    RegCloseKey key
    RegistryKeyExists = True
End Function

Private Sub CheckRedirection(ByVal subkey As String)
    Dim names As Variant, item As Variant, found As Boolean, ignored As String
    names = Array("TreatAs", "AutoTreatAs", "AppID", "LocalService")
    For Each item In names
        If RegistryKeyExists(subkey & "\" & CStr(item)) Then Reject "COM redirection is unsupported: " & CStr(item)
        ignored = RegistryText(subkey, CStr(item), found)
        If found Then Reject "COM redirection is unsupported: " & CStr(item)
    Next item
End Sub

Private Sub CheckRegistration()
    Dim found As Boolean, value As String, root As String, closeQuote As Long
    value = RegistryText("Vuniq.VuniqConnector\CLSID", "", found)
    If Not found Then Reject "32-bit VuniqConnector CLSID is missing"
    If StrComp(value, CONNECTOR_CLSID, vbTextCompare) <> 0 Then Reject "Unexpected VuniqConnector CLSID"
    CheckRedirection "Vuniq.VuniqConnector"
    CheckRedirection "Vuniq.VuniqConnector\CLSID"
    root = "CLSID\" & CONNECTOR_CLSID
    CheckRedirection root
    If RegistryKeyExists(root & "\InprocServer32") Then Reject "An in-process COM server is unsupported"
    value = RegistryText(root & "\LocalServer32", "", found)
    If Not found Then Reject "32-bit LocalServer32 is missing"
    value = Trim$(value)
    If Left$(value, 1) = Chr$(34) Then
        closeQuote = InStr(2, value, Chr$(34), vbBinaryCompare)
        If closeQuote = 0 Then Reject "Unclosed COM executable quote"
        If Len(Trim$(Mid$(value, closeQuote + 1))) <> 0 Then Reject "COM executable arguments are unsupported"
        value = Mid$(value, 2, closeQuote - 2)
    Else
        If InStr(value, " ") <> 0 Or InStr(value, vbTab) <> 0 Then Reject "Ambiguous COM executable command"
    End If
    If StrComp(CanonicalPath(value), mExpectedExe, vbTextCompare) <> 0 Then Reject "COM executable differs from configured Vuniq"
    value = RegistryText(root & "\LocalServer32", "ServerExecutable", found)
    If found Then
        If StrComp(CanonicalPath(value), mExpectedExe, vbTextCompare) <> 0 Then Reject "COM ServerExecutable differs from configured Vuniq"
    End If
End Sub

Private Function ObserveIdentity() As String
    Dim snapshot As Long, process As Long, item As PROCESSENTRY32
    Dim result As Long, ownSession As Long, targetSession As Long, count As Long
    Dim created As FILETIME, exited As FILETIME, kernel As FILETIME, user As FILETIME
    Dim path As String, filename As String, identity As String
    Dim savedNumber As Long, savedDescription As String
    On Error GoTo Failed
    If ProcessIdToSessionId(GetCurrentProcessId(), ownSession) = 0 Then Reject "Cannot read NILIT Windows session"
    If ownSession = 0 Then Reject "An interactive operator session is required"
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    If snapshot = INVALID_HANDLE_VALUE Then Reject "Cannot enumerate running processes"
    item.Size = Len(item)
    result = Process32First(snapshot, item)
    If result = 0 Then Reject "Cannot inspect running processes"
    Do While result <> 0
        filename = item.ExeFile
        If InStr(filename, vbNullChar) <> 0 Then filename = Left$(filename, InStr(filename, vbNullChar) - 1)
        If StrComp(filename, "Vuniq.exe", vbTextCompare) = 0 Then
            If Len(identity) <> 0 Then Reject "More than one Vuniq process exists"
            process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, item.ProcessId)
            If process = 0 Then Reject "Cannot inspect Vuniq process"
            If ProcessIdToSessionId(item.ProcessId, targetSession) = 0 Then Reject "Cannot inspect Vuniq session"
            If targetSession <> ownSession Then Reject "Vuniq belongs to another Windows session"
            count = 32768
            path = String$(count, vbNullChar)
            If QueryFullProcessImageName(process, 0, StrPtr(path), count) = 0 Then Reject "Cannot read Vuniq executable path"
            path = CanonicalPath(Left$(path, count))
            If StrComp(path, mExpectedExe, vbTextCompare) <> 0 Then Reject "Another Vuniq executable is running"
            If GetProcessTimes(process, created, exited, kernel, user) = 0 Then Reject "Cannot read Vuniq creation time"
            If exited.Low <> 0 Or exited.High <> 0 Then Reject "Vuniq exited during identity inspection"
            identity = CStr(item.ProcessId) & ":" & Hex$(created.High) & ":" & Hex$(created.Low) & ":" & CStr(targetSession) & ":" & LCase$(path)
            CloseHandle process: process = 0
        End If
        result = Process32Next(snapshot, item)
    Loop
    ' ERROR_NO_MORE_FILES is the normal end of a Toolhelp enumeration.
    If Err.LastDllError <> 18 Then Reject "Process enumeration ended unexpectedly"
    CloseHandle snapshot: snapshot = 0
    ObserveIdentity = identity
    Exit Function
Failed:
    savedNumber = Err.Number: savedDescription = Err.Description
    If process <> 0 Then CloseHandle process
    If snapshot <> 0 And snapshot <> INVALID_HANDLE_VALUE Then CloseHandle snapshot
    Err.Raise savedNumber, "VuniqLink", savedDescription
End Function

Private Sub CheckCoordinates(ByVal port As Integer, ByVal head As Integer)
    If port < 1 Or port > 8 Or head < 1 Or head > 8 Then Reject "Head address is outside the EF range"
End Sub

Private Function HeadAddress(ByVal port As Integer, ByVal head As Integer, ByVal field As Integer) As String
    CheckCoordinates port, head
    Select Case field
        Case 1: HeadAddress = "99;1;N" & CStr(10 * port + head)
        Case 2: HeadAddress = "99;1;N" & CStr(100 + 10 * port + head)
        Case 3: HeadAddress = "99;1;F" & CStr(port) & "." & CStr(head)
        Case 4: HeadAddress = "99;1;N" & CStr(200 + 10 * port + head)
        Case 5: HeadAddress = CStr(port) & ";1;S" & CStr(5 + head * 6)
        Case 6: HeadAddress = CStr(port) & ";1;S" & CStr(4 + head * 6)
        Case 7: HeadAddress = CStr(port) & ";1;DW" & CStr(80 + head) & ".0"
        Case Else: Reject "Unsupported head field"
    End Select
End Function

Private Function CommAddress(ByVal port As Integer) As String
    CheckCoordinates port, 1
    CommAddress = "100;1;Port" & CStr(port) & ".StCommErr[1]"
End Function

Private Sub RegisterItems()
    Dim port As Integer, head As Integer, field As Integer, valid As Long, address As String
    For port = 1 To 8
        For head = 1 To 8
            For field = 1 To 7
                mConnector.AddItem HeadAddress(port, head, field)
            Next field
        Next head
    Next port
    For field = 91 To 98
        mConnector.AddItem "99;1;N" & CStr(field)
    Next field
    For port = 1 To 8
        address = CommAddress(port)
        valid = -987654321
        mConnector.IsValidReference address, valid
        If valid = -987654321 Then Reject "Communication diagnostic validity was not returned"
        mCommSupported(port) = (valid <> 0)
        If Not mCommSupported(port) And mCommEverSupported(port) Then Reject "Previously supported communication diagnostic is unavailable"
        If mCommSupported(port) Then
            mCommEverSupported(port) = True
            mConnector.AddItem address
        End If
    Next port
End Sub

Public Function LinkOpen(ByVal expectedExe As String, ByRef problem As String) As Boolean
    Dim before As String, after As String
    On Error GoTo Failed
    problem = ""
    LinkClose
#If COUNTER_TEST Then
    Reject "Test build cannot activate Vuniq; inject a mock connector"
#Else
    mExpectedExe = CanonicalPath(expectedExe)
    If StrComp(Mid$(mExpectedExe, InStrRev(mExpectedExe, "\") + 1), "Vuniq.exe", vbTextCompare) <> 0 Then Reject "Expected Vuniq.exe"
    CheckRegistration
    before = ObserveIdentity()
    Set mConnector = CreateObject("Vuniq.VuniqConnector")
    after = ObserveIdentity()
    If Len(after) = 0 Then Reject "Vuniq is absent after COM activation"
    If Len(before) <> 0 And before <> after Then Reject "Vuniq identity changed during COM activation"
    mIdentity = after
    RegisterItems
    AssertIdentity
    LinkOpen = True
#End If
    Exit Function
Failed:
    problem = Failure("Open Vuniq link")
    LinkClose
End Function

Public Sub LinkClose()
    Dim port As Integer
    ' Never call RemoveAllItems: its cross-client scope is not documented.
    On Error Resume Next
    Set mConnector = Nothing
    mIdentity = ""
    Erase mRetryPublished
    For port = 1 To 8
        mCommSupported(port) = False
    Next port
End Sub

Public Function LinkIdentity() As String
    LinkIdentity = mIdentity
End Function

Public Function LinkCheckIdentity(ByRef problem As String) As Boolean
    Dim current As String
    On Error GoTo Failed
    problem = ""
    If mConnector Is Nothing Then Reject "Vuniq link is closed"
#If COUNTER_TEST Then
    current = CStr(mConnector.Identity)
#Else
    current = ObserveIdentity()
#End If
    If Len(current) = 0 Or current <> mIdentity Then Reject "Vuniq process identity changed or disappeared"
    LinkCheckIdentity = True
    Exit Function
Failed:
    problem = Failure("Check Vuniq identity")
End Function

Private Sub AssertIdentity()
    Dim problem As String
    If Not LinkCheckIdentity(problem) Then Reject problem
End Sub

Private Function StrictLong(ByVal text As String, ByVal minimum As Long, ByVal maximum As Long) As Long
    Dim position As Long, digit As Long, sign As Long, magnitude As Double
    text = StripPadding(text)
    If Len(text) = 0 Or Len(text) > 32 Then Reject "Empty or oversized numeric value"
    position = 1: sign = 1
    If Left$(text, 1) = "-" Or Left$(text, 1) = "+" Then
        If Left$(text, 1) = "-" Then sign = -1
        position = 2
    End If
    If position > Len(text) Then Reject "A numeric value has no digits"
    For position = position To Len(text)
        digit = AscW(Mid$(text, position, 1)) - 48
        If digit < 0 Or digit > 9 Then Reject "A numeric value contains non-decimal text"
        magnitude = magnitude * 10# + digit
        If magnitude > 2147483648# Then Reject "Numeric value overflows Long"
    Next position
    magnitude = magnitude * sign
    If magnitude < minimum Or magnitude > maximum Then Reject "Numeric value is outside its allowed range"
    StrictLong = CLng(magnitude)
End Function

Private Function ReadNumber(ByVal address As String, ByVal minimum As Long, ByVal maximum As Long, ByRef rawState As String) As Long
    Dim value As String, state As String, dataType As Long
    value = Space$(30): state = Space$(30): dataType = -987654321
    mConnector.GetItemValue address, value, state, dataType
    If Len(value) > 4096 Or Len(state) > 4096 Then Reject "Oversized Vuniq response"
    rawState = address & "=" & StripPadding(state) & ";type=" & CStr(dataType)
    If dataType = -987654321 Then Reject "Vuniq did not return a datatype"
    ReadNumber = StrictLong(value, minimum, maximum)
End Function

Private Function ReadOptionalNumber(ByVal address As String, ByVal minimum As Long, ByVal maximum As Long, ByVal defaultValue As Long, ByRef rawState As String) As Long
    Dim value As String, state As String, dataType As Long, trimmed As String
    value = Space$(30): state = Space$(30): dataType = -987654321
    mConnector.GetItemValue address, value, state, dataType
    If Len(value) > 4096 Or Len(state) > 4096 Then Reject "Oversized Vuniq response"
    rawState = address & "=" & StripPadding(state) & ";type=" & CStr(dataType)
    If dataType = -987654321 Then
        ReadOptionalNumber = defaultValue
        Exit Function
    End If
    trimmed = Trim$(StripPadding(value))
    If Len(trimmed) = 0 Then
        ReadOptionalNumber = defaultValue
    Else
        ReadOptionalNumber = StrictLong(value, minimum, maximum)
    End If
End Function

Private Function DiagnosticText(ByVal value As String) As String
    Dim clipped As Boolean
    clipped = (Len(value) > 128)
    value = Left$(value, 128)
    value = Replace(value, "\", "\\")
    value = Replace(value, vbNullChar, "\0")
    value = Replace(value, vbCr, "\r")
    value = Replace(value, vbLf, "\n")
    value = Replace(value, vbTab, "\t")
    value = Replace(value, Chr$(34), "\" & Chr$(34))
    If clipped Then value = value & "...[truncated]"
    DiagnosticText = Chr$(34) & value & Chr$(34)
End Function

Private Function ReadCommunicationError(ByVal address As String, ByRef rawState As String) As Boolean
    Dim value As String, state As String, dataType As Long, parsed As String
    value = Space$(30): state = Space$(30): dataType = -987654321
    mConnector.GetItemValue address, value, state, dataType
    rawState = address & "=" & DiagnosticText(StripPadding(state)) & ";type=" & CStr(dataType) & ";value=" & DiagnosticText(value)
    If Len(value) > 4096 Or Len(state) > 4096 Then Reject "Oversized Vuniq communication response"
    ' Vuniq 5 VBDemo documents states 4/5 as good/new, type 3 as Boolean,
    ' and Boolean text as True. StCommErr is true when communication fails.
    state = StripPadding(state)
    If state <> "4" And state <> "5" Then Reject "Communication diagnostic has no valid current value"
    If dataType <> 1 And dataType <> 3 Then Reject "Unsupported communication diagnostic datatype"
    parsed = UCase$(StripPadding(value))
    Select Case parsed
        Case "0": ReadCommunicationError = False
        Case "1": ReadCommunicationError = True
        Case "FALSE"
            If dataType <> 3 Then Reject "Boolean text has a non-Boolean datatype"
            ReadCommunicationError = False
        Case "TRUE"
            If dataType <> 3 Then Reject "Boolean text has a non-Boolean datatype"
            ReadCommunicationError = True
        Case Else
            Reject "Unrecognized communication diagnostic value"
    End Select
End Function

Public Function LinkReadHead(ByVal port As Integer, ByVal head As Integer, ByRef sample As HeadSample, ByRef rawStates As String, ByRef problem As String) As Boolean
    Dim nextSample As HeadSample, raw As String
    On Error GoTo Failed
    problem = "": rawStates = ""
    CheckCoordinates port, head
    AssertIdentity
    nextSample.Maintenance = ReadOptionalNumber(HeadAddress(port, head, 4), 0, 5, 0, raw)
    rawStates = raw
    nextSample.WipingDate = ReadOptionalNumber(HeadAddress(port, head, 5), 0, 31, 0, raw)
    rawStates = rawStates & " | " & raw
    nextSample.WipingTime = ReadOptionalNumber(HeadAddress(port, head, 6), 0, 2359, 0, raw)
    rawStates = rawStates & " | " & raw
    If nextSample.WipingTime Mod 100 > 59 Then Reject "Wiping time has an invalid minute component"
    nextSample.WindingRaw = ReadOptionalNumber(HeadAddress(port, head, 7), -32768, 65535, 0, raw)
    rawStates = rawStates & " | " & raw
    If nextSample.WindingRaw < 0 Then nextSample.WindingRaw = nextSample.WindingRaw + 65536
    AssertIdentity
    sample = nextSample
    LinkReadHead = True
    Exit Function
Failed:
    problem = Failure("Read head " & CStr(port) & "/" & CStr(head))
End Function

Public Function LinkReadComm(ByVal port As Integer, ByRef supported As Boolean, ByRef healthy As Boolean, ByRef rawState As String, ByRef problem As String) As Boolean
    Dim hasError As Boolean
    On Error GoTo Failed
    problem = "": rawState = "": supported = False: healthy = False
    CheckCoordinates port, 1
    AssertIdentity
    supported = mCommSupported(port)
    If Not supported Then
        If mCommEverSupported(port) Then Reject "Previously supported communication diagnostic is unavailable"
        LinkReadComm = True
        Exit Function
    End If
    hasError = ReadCommunicationError(CommAddress(port), rawState)
    AssertIdentity
    healthy = Not hasError
    LinkReadComm = True
    Exit Function
Failed:
    problem = Failure("Read station communication " & CStr(port))
End Function

Public Function LinkWriteHead(ByVal port As Integer, ByVal head As Integer, ByRef h As HeadState, ByRef problem As String) As Boolean
    Dim hhmm As Long
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, head
    If Not h.Initialized Then Reject "Cannot publish an uninitialized head"
    If h.Mode < 1 Or h.Mode > 4 Then Reject "Invalid head mode"
    If h.PendingMaintenanceClear And h.Mode <> ENGINE_MODE_GREEN Then Reject "Maintenance clear requires green mode"
    If h.Blink <> 0 And h.Blink <> 1 Then Reject "Invalid head blink"
    If h.ElapsedMs < 0# Then Reject "Invalid head duration"
    hhmm = EngineHHMM(h.ElapsedMs)
    If hhmm < 0 Or hhmm > 32759 Or hhmm Mod 100 > 59 Then Reject "Invalid head timer"
    AssertIdentity
    mConnector.SetItemValue HeadAddress(port, head, 1), CStr(h.Mode)
    mConnector.SetItemValue HeadAddress(port, head, 2), CStr(hhmm)
    mConnector.SetItemValue HeadAddress(port, head, 3), CStr(h.Blink)
    If h.PendingMaintenanceClear Then mConnector.SetItemValue HeadAddress(port, head, 4), "0"
    AssertIdentity
    LinkWriteHead = True
    Exit Function
Failed:
    problem = Failure("Publish head " & CStr(port) & "/" & CStr(head))
End Function

Public Function LinkWriteSummary(ByRef heads() As HeadState, ByRef problem As String) As Boolean
    Dim counts(1 To 8) As Long, port As Integer, head As Integer, index As Integer, offset As Integer
    On Error GoTo Failed
    problem = ""
    If LBound(heads, 1) <> 1 Or UBound(heads, 1) <> 8 Or LBound(heads, 2) <> 1 Or UBound(heads, 2) <> 8 Then Reject "Expected an 8 by 8 head array"
    For port = 1 To 8
        offset = 0
        If port > 4 Then offset = 4
        For head = 1 To 8
            If heads(port, head).Initialized Then
                If heads(port, head).Mode < 1 Or heads(port, head).Mode > 4 Then Reject "Invalid initialized summary mode"
                index = 5 - heads(port, head).Mode + offset
                counts(index) = counts(index) + 1
            End If
        Next head
    Next port
    AssertIdentity
    For index = 1 To 8
        mConnector.SetItemValue "99;1;N" & CStr(90 + index), CStr(counts(index))
    Next index
    AssertIdentity
    LinkWriteSummary = True
    Exit Function
Failed:
    problem = Failure("Publish summaries")
End Function

Public Function LinkRequestStatus(ByVal port As Integer, ByRef problem As String) As Boolean
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, 1
    AssertIdentity
    mConnector.SetItemValue CStr(port) & ";1;StatRequest", "1"
    AssertIdentity
    LinkRequestStatus = True
    Exit Function
Failed:
    problem = Failure("Request port status " & CStr(port))
End Function

' Display-quality tags are internal DataTable fields only. Never write the
' independent Vuniq native clock (N990..N996) or any serial-port command here.
' Freshness means an accepted API observation, not a verified PLC wire update.
Private Function DisplayNumber(ByVal index As Integer) As String
    DisplayNumber = "99;1;N" & CStr(index)
End Function

Private Function DisplayString(ByVal index As Integer) As String
    DisplayString = "99;1;S" & CStr(index)
End Function

Private Sub WriteDisplayClock(ByVal minutesIndex As Integer, ByVal secondsIndex As Integer, ByVal yearIndex As Integer, ByVal monthIndex As Integer, ByVal dayIndex As Integer, ByVal atLocal As Date)
    mConnector.SetItemValue DisplayNumber(yearIndex), CStr(Year(atLocal))
    mConnector.SetItemValue DisplayNumber(monthIndex), CStr(Month(atLocal))
    mConnector.SetItemValue DisplayNumber(dayIndex), CStr(Day(atLocal))
    mConnector.SetItemValue DisplayNumber(minutesIndex), CStr(CLng(Hour(atLocal)) * 60& + Minute(atLocal))
    mConnector.SetItemValue DisplayNumber(secondsIndex), CStr(Second(atLocal))
End Sub

Public Function LinkDisplayStart(ByRef lastRead() As Date, ByRef problem As String) As Boolean
    Dim index As Integer, valid As Long, address As String
    Dim port As Integer, head As Integer, oldest As Date, allRead As Boolean, label As String
    On Error GoTo Failed
    problem = ""
    AssertIdentity
    For index = 800 To 911
        address = DisplayNumber(index)
        valid = 0: mConnector.IsValidReference address, valid
        If valid = 0 Then Reject "Display-quality numeric tag unavailable: " & address
        mConnector.AddItem address
    Next index
    For index = 960 To 964
        address = DisplayNumber(index)
        valid = 0: mConnector.IsValidReference address, valid
        If valid = 0 Then Reject "Display heartbeat tag unavailable: " & address
        mConnector.AddItem address
    Next index
    For index = 1000 To 1063
        address = DisplayNumber(index)
        valid = 0: mConnector.IsValidReference address, valid
        If valid = 0 Then Reject "Display retry flag unavailable: " & address
        mConnector.AddItem address
    Next index
    For index = 64 To 135
        address = DisplayString(index)
        valid = 0: mConnector.IsValidReference address, valid
        If valid = 0 Then Reject "Display-quality timestamp unavailable: " & address
        mConnector.AddItem address
    Next index
    ' Invalidate the old process heartbeat before touching any head metadata.
    mConnector.SetItemValue DisplayNumber(960), "-1"
    Erase mRetryPublished
    For index = 1000 To 1063
        mConnector.SetItemValue DisplayNumber(index), "0"
    Next index
    For index = 896 To 903
        mConnector.SetItemValue DisplayNumber(index), "0"
    Next index
    For index = 800 To 895
        mConnector.SetItemValue DisplayNumber(index), "0"
    Next index
    ' Retain accepted timestamps across a link retry within this process. A
    ' process restart supplies zeros: restored counter time is not a new read.
    For port = 1 To 8
        allRead = True: oldest = 0
        For head = 1 To 8
            index = (port - 1) * 8 + head - 1
            label = "--"
            If lastRead(port, head) <> 0 Then
                label = Format$(lastRead(port, head), "dd/mm/yyyy hh:nn:ss")
                If oldest = 0 Or lastRead(port, head) < oldest Then oldest = lastRead(port, head)
            Else
                allRead = False
            End If
            mConnector.SetItemValue DisplayString(64 + index), label
        Next head
        label = "--"
        If allRead Then label = Format$(oldest, "dd/mm/yyyy hh:nn:ss")
        mConnector.SetItemValue DisplayString(127 + port), label
    Next port
    AssertIdentity
    LinkDisplayStart = True
    Exit Function
Failed:
    problem = Failure("Initialize display-quality tags")
End Function

Public Function LinkDisplayReading(ByVal port As Integer, ByVal hasPriorGood As Boolean, ByRef problem As String) As Boolean
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, 1
    AssertIdentity
    If hasPriorGood Then
        ' Keep the last accepted display during a normal poll, bounded by the
        ' independent 30-second screen age checks. No timestamp is refreshed.
        mConnector.SetItemValue DisplayNumber(895 + port), "5"
    Else
        mConnector.SetItemValue DisplayNumber(895 + port), "1"
    End If
    AssertIdentity
    LinkDisplayReading = True
    Exit Function
Failed:
    problem = Failure("Mark API read in progress")
End Function

' A retry flag describes an actual API reacquisition of a previously gapped
' head. It never claims a physical PLC handshake, and normal polls/debounce
' do not set it. The screen must independently expire a frozen heartbeat.
Public Function LinkDisplayRetryStart(ByVal port As Integer, ByRef retryHead() As Boolean, ByRef problem As String) As Boolean
    Dim head As Integer
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, 1
    AssertIdentity
    For head = 1 To 8
        If retryHead(head) Then
            mConnector.SetItemValue DisplayNumber(1000 + (port - 1) * 8 + head - 1), "1"
            mRetryPublished(port, head) = True
        End If
    Next head
    AssertIdentity
    LinkDisplayRetryStart = True
    Exit Function
Failed:
    problem = Failure("Mark actual API retry")
End Function

Public Function LinkDisplayRetryEnd(ByVal port As Integer, ByRef problem As String) As Boolean
    Dim head As Integer
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, 1
    AssertIdentity
    For head = 1 To 8
        If mRetryPublished(port, head) Then
            mConnector.SetItemValue DisplayNumber(1000 + (port - 1) * 8 + head - 1), "0"
            mRetryPublished(port, head) = False
        End If
    Next head
    AssertIdentity
    LinkDisplayRetryEnd = True
    Exit Function
Failed:
    problem = Failure("Complete API retry indication")
End Function

Public Function LinkDisplayPort(ByVal port As Integer, ByRef quality() As Boolean, ByRef lastRead() As Date, ByRef problem As String) As Boolean
    Dim head As Integer, index As Integer, good As Integer, status As Integer
    Dim oldest As Date, allRead As Boolean, label As String, atLocal As Date
    On Error GoTo Failed
    problem = ""
    CheckCoordinates port, 1
    AssertIdentity
    allRead = True
    For head = 1 To 8
        index = (port - 1) * 8 + head - 1
        If quality(port, head) Then good = good + 1
        label = "--"
        If lastRead(port, head) <> 0 Then
            label = Format$(lastRead(port, head), "dd/mm/yyyy hh:nn:ss")
            If oldest = 0 Or lastRead(port, head) < oldest Then oldest = lastRead(port, head)
        Else
            allRead = False
        End If
        mConnector.SetItemValue DisplayString(64 + index), label
        If quality(port, head) Then
            mConnector.SetItemValue DisplayNumber(800 + index), "1"
        Else
            mConnector.SetItemValue DisplayNumber(800 + index), "0"
        End If
    Next head
    label = "--"
    If allRead Then label = Format$(oldest, "dd/mm/yyyy hh:nn:ss")
    mConnector.SetItemValue DisplayString(127 + port), label
    status = 4
    If good > 0 Then status = 3
    If good = 8 Then status = 2
    atLocal = Now
    WriteDisplayClock 863 + port, 903 + port, 871 + port, 879 + port, 887 + port, atLocal
    ' Status is the port transaction commit; clock is not a head freshness claim.
    mConnector.SetItemValue DisplayNumber(895 + port), CStr(status)
    ' A frozen synchronous COM call cannot refresh this completion heartbeat.
    WriteDisplayClock 960, 964, 961, 962, 963, atLocal
    AssertIdentity
    LinkDisplayPort = True
    Exit Function
Failed:
    problem = Failure("Publish display-quality metadata")
End Function

Public Sub LinkDisplayStop()
    Dim index As Integer
    On Error GoTo Done
    AssertIdentity
    mConnector.SetItemValue DisplayNumber(960), "-1"
    For index = 1000 To 1063
        mConnector.SetItemValue DisplayNumber(index), "0"
    Next index
    Erase mRetryPublished
    For index = 896 To 903
        mConnector.SetItemValue DisplayNumber(index), "0"
    Next index
Done:
End Sub

#If COUNTER_TEST Then
' The shipped build does not contain this entry point or any mock mode.
Public Function LinkTestAttach(ByVal mock As Object, ByRef problem As String) As Boolean
    On Error GoTo Failed
    problem = ""
    LinkClose
    Set mConnector = mock
    mIdentity = CStr(mock.Identity)
    RegisterItems
    AssertIdentity
    LinkTestAttach = True
    Exit Function
Failed:
    problem = Failure("Attach mock connector")
    LinkClose
End Function

Public Sub LinkTestReset()
    Dim port As Integer
    LinkClose
    For port = 1 To 8
        mCommEverSupported(port) = False
    Next port
End Sub
#End If
