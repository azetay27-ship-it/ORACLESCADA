Attribute VB_Name = "Platform"
Option Explicit

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
Private Type GUID
    A As Long
    B As Integer
    C As Integer
    D(0 To 7) As Byte
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
Private Type STARTUPINFO
    Size As Long
    Reserved As Long
    Desktop As Long
    Title As Long
    X As Long
    Y As Long
    Width As Long
    Height As Long
    CharsX As Long
    CharsY As Long
    Fill As Long
    Flags As Long
    ShowWindow As Integer
    ReservedSize As Integer
    ReservedPointer As Long
    StdInput As Long
    StdOutput As Long
    StdError As Long
End Type
Private Type PROCESS_INFORMATION
    Process As Long
    Thread As Long
    ProcessId As Long
    ThreadId As Long
End Type
Private Declare Function GetTickCount Lib "kernel32" () As Long
Private Declare Sub GetSystemTime Lib "kernel32" (ByRef value As SYSTEMTIME)
Private Declare Function CoCreateGuid Lib "ole32" (ByRef value As GUID) As Long
Private Declare Function StringFromGUID2 Lib "ole32" (ByRef value As GUID, ByVal text As Long, ByVal count As Long) As Long
Private Declare Function CreateMutex Lib "kernel32" Alias "CreateMutexW" (ByVal attributes As Long, ByVal own As Long, ByVal name As Long) As Long
Private Declare Function CloseHandle Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function ReleaseMutex Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function CreateToolhelp32Snapshot Lib "kernel32" (ByVal flags As Long, ByVal processId As Long) As Long
Private Declare Function Process32First Lib "kernel32" (ByVal snapshot As Long, ByRef entry As PROCESSENTRY32) As Long
Private Declare Function Process32Next Lib "kernel32" (ByVal snapshot As Long, ByRef entry As PROCESSENTRY32) As Long
Private Declare Function GetCurrentProcessId Lib "kernel32" () As Long
Private Declare Function GetPrivateProfileString Lib "kernel32" Alias "GetPrivateProfileStringW" (ByVal section As Long, ByVal key As Long, ByVal fallback As Long, ByVal value As Long, ByVal capacity As Long, ByVal file As Long) As Long
Private Declare Function CreateDirectory Lib "kernel32" Alias "CreateDirectoryW" (ByVal path As Long, ByVal attributes As Long) As Long
Private Declare Function GetFileAttributes Lib "kernel32" Alias "GetFileAttributesW" (ByVal path As Long) As Long
Private Declare Function CreateFile Lib "kernel32" Alias "CreateFileW" (ByVal path As Long, ByVal access As Long, ByVal share As Long, ByVal security As Long, ByVal disposition As Long, ByVal flags As Long, ByVal template As Long) As Long
Private Declare Function WriteFile Lib "kernel32" (ByVal handle As Long, ByVal buffer As Long, ByVal count As Long, ByRef written As Long, ByVal overlapped As Long) As Long
Private Declare Function GetFileSize Lib "kernel32" (ByVal handle As Long, ByRef high As Long) As Long
Private Declare Function SetFilePointer Lib "kernel32" (ByVal handle As Long, ByVal distance As Long, ByVal high As Long, ByVal method As Long) As Long
Private Declare Function FlushFileBuffers Lib "kernel32" (ByVal handle As Long) As Long
Private Declare Function GetACP Lib "kernel32" () As Long
Private Declare Function OpenProcess Lib "kernel32" (ByVal access As Long, ByVal inherit As Long, ByVal pid As Long) As Long
Private Declare Function WaitForSingleObject Lib "kernel32" (ByVal handle As Long, ByVal timeout As Long) As Long
Private Declare Function TerminateProcess Lib "kernel32" (ByVal handle As Long, ByVal code As Long) As Long
Private Declare Function CreateProcess Lib "kernel32" Alias "CreateProcessW" (ByVal application As Long, ByVal commandLine As Long, ByVal processAttributes As Long, ByVal threadAttributes As Long, ByVal inherit As Long, ByVal flags As Long, ByVal environment As Long, ByVal directory As Long, ByRef startup As STARTUPINFO, ByRef process As PROCESS_INFORMATION) As Long
Private mMutex As Long
Private mExportProcess As Long
Private mExportStarted As Double

Public Function TickMs() As Double
    Dim value As Long
    value = GetTickCount()
    TickMs = value
    If value < 0 Then TickMs = CDbl(value) + 4294967296#
End Function

Public Function TickElapsed(ByVal before As Double, ByVal after As Double) As Double
    TickElapsed = after - before
    If TickElapsed < 0# Then TickElapsed = TickElapsed + 4294967296#
End Function

Public Function UtcNow() As Date
    Dim value As SYSTEMTIME
    GetSystemTime value
    UtcNow = DateSerial(value.Year, value.Month, value.Day) + TimeSerial(value.Hour, value.Minute, value.Second) + CDbl(value.Milliseconds) / 86400000#
End Function

Public Function NewEpoch() As String
    Dim value As GUID, buffer As String
    If CoCreateGuid(value) <> 0 Then Err.Raise vbObjectError + 2400, , "Cannot create state identifier"
    buffer = String$(39, vbNullChar)
    If StringFromGUID2(value, StrPtr(buffer), 39) <> 39 Then Err.Raise vbObjectError + 2401, , "Cannot format state identifier"
    NewEpoch = Mid$(buffer, 2, 36)
End Function

Public Function FileExists(ByVal path As String) As Boolean
    Dim flags As Long
    flags = GetFileAttributes(StrPtr(path))
    If flags <> -1 Then FileExists = ((flags And 16&) = 0)
End Function

Public Sub EnsureFolder(ByVal path As String)
    Dim flags As Long, parent As String, cut As Long
    If Len(path) < 4 Or Len(path) > 230 Or Mid$(path, 2, 2) <> ":\" Then Err.Raise vbObjectError + 2402, , "Local data directory must be an absolute short Windows path"
    flags = GetFileAttributes(StrPtr(path))
    If flags <> -1 Then
        If (flags And 16&) = 0 Or (flags And 1024&) <> 0 Then Err.Raise vbObjectError + 2403, , "Data path is not an ordinary directory"
        Exit Sub
    End If
    cut = InStrRev(path, "\")
    parent = Left$(path, cut - 1)
    If Len(parent) > 3 Then EnsureFolder parent
    If CreateDirectory(StrPtr(path), 0) = 0 Then Err.Raise vbObjectError + 2404, , "Cannot create data directory (Windows " & CStr(Err.LastDllError) & ")"
End Sub

Public Function DefaultDataFolder() As String
    Dim base As String
    base = Environ$("LOCALAPPDATA")
    If Len(base) = 0 Then Err.Raise vbObjectError + 2405, , "LOCALAPPDATA is unavailable"
    DefaultDataFolder = base & "\NILITLegacyCounter\EF-v1"
End Function

Public Function IniValue(ByVal file As String, ByVal key As String) As String
    Dim section As String, fallback As String, value As String, count As Long
    section = "General": fallback = "": value = String$(2048, vbNullChar)
    count = GetPrivateProfileString(StrPtr(section), StrPtr(key), StrPtr(fallback), StrPtr(value), Len(value), StrPtr(file))
    If count = 0 Or count >= Len(value) - 1 Then Err.Raise vbObjectError + 2406, , "Missing or oversized barmag.ini entry: " & key
    IniValue = Trim$(Left$(value, count))
End Function

Public Function AcquireCounter(ByRef problem As String) As Boolean
    Dim name As String, errorCode As Long, snapshot As Long, entry As PROCESSENTRY32, found As Long, filename As String
    On Error GoTo Failed
    name = "Global\NILIT.EF.LegacyCounter.v1"
    mMutex = CreateMutex(0, 1, StrPtr(name))
    errorCode = Err.LastDllError
    If mMutex = 0 Or errorCode = 183 Then Err.Raise vbObjectError + 2407, , "Another EF counter is already running or the counter lock is inaccessible"
    snapshot = CreateToolhelp32Snapshot(2, 0)
    If snapshot = -1 Then Err.Raise vbObjectError + 2408, , "Cannot check for the old NILIT process"
    entry.Size = Len(entry)
    found = Process32First(snapshot, entry)
    If found = 0 Then Err.Raise vbObjectError + 2409, , "Cannot inspect running processes"
    Do While found <> 0
        filename = Left$(entry.ExeFile, InStr(entry.ExeFile, vbNullChar) - 1)
        If entry.ProcessId <> GetCurrentProcessId() And LCase$(filename) = "nilit.exe" Then Err.Raise vbObjectError + 2410, , "Close the other nilit.exe before starting this counter"
        found = Process32Next(snapshot, entry)
    Loop
    If Err.LastDllError <> 18 Then Err.Raise vbObjectError + 2418, , "Process enumeration did not finish normally"
    CloseHandle snapshot
    AcquireCounter = True
    Exit Function
Failed:
    problem = Err.Description
    If snapshot <> 0 And snapshot <> -1 Then CloseHandle snapshot
    ReleaseCounter
End Function

Public Sub ReleaseCounter()
    If mMutex <> 0 Then
        ReleaseMutex mMutex
        CloseHandle mMutex
        mMutex = 0
    End If
End Sub

Public Function SapCodePageReady() As Boolean
    SapCodePageReady = (GetACP() = 1255)
End Function

Private Function Csv(ByVal value As String) As String
    Csv = Chr$(34) & Replace$(value, Chr$(34), Chr$(34) & Chr$(34)) & Chr$(34)
End Function

Public Function AuditWrite(ByVal folder As String, ByVal kind As String, ByVal port As Integer, ByVal head As Integer, ByVal message As String, ByRef problem As String) As Boolean
    Dim handle As Long, file As String, text As String, size As Long, high As Long, written As Long
    On Error GoTo Failed
    file = folder & "\audit-" & Format$(UtcNow(), "yyyymmdd") & ".csv"
    handle = CreateFile(StrPtr(file), &H40000000, 1, 0, 4, &H80000000, 0)
    If handle = -1 Then Err.Raise vbObjectError + 2411, , "Cannot open local audit"
    size = GetFileSize(handle, high)
    If SetFilePointer(handle, 0, 0, 2) = -1 Then Err.Raise vbObjectError + 2417, , "Cannot seek local audit"
    If size = 0 And high = 0 Then
        text = ChrW$(&HFEFF) & "utc,kind,port,head,detail" & vbCrLf
    End If
    text = text & Format$(UtcNow(), "yyyy-mm-dd\Thh:nn:ss") & "Z," & Csv(kind) & "," & CStr(port) & "," & CStr(head) & "," & Csv(message) & vbCrLf
    If WriteFile(handle, StrPtr(text), LenB(text), written, 0) = 0 Or written <> LenB(text) Then Err.Raise vbObjectError + 2412, , "Cannot write local audit"
    If FlushFileBuffers(handle) = 0 Then Err.Raise vbObjectError + 2413, , "Cannot flush local audit"
    CloseHandle handle
    AuditWrite = True
    Exit Function
Failed:
    problem = Err.Description
    If handle <> 0 And handle <> -1 Then CloseHandle handle
End Function

Public Function ExportWorkerStep(ByVal folder As String, ByRef problem As String, Optional ByVal statusEpoch As String = "") As Boolean
    ' Direct SAP append is active in LegacyExport. No child process is required.
    problem = ""
    ExportWorkerStep = True
End Function

Public Sub ReleaseWorkerHandle()
    ' An in-flight export may finish after the UI closes; never kill it on exit.
    If mExportProcess <> 0 Then CloseHandle mExportProcess
    mExportProcess = 0
End Sub
