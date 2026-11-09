Attribute VB_Name = "CounterRuntime"
Option Explicit

Private Const INI_FILE As String = "C:\Vuniq50\barmag\barmag.ini"
Private Const VUNIQ_EXE As String = "C:\Vuniq50\bin\Vuniq.exe"
Private Const QUEUE_LIMIT As Long = 8192
Private mHeads(1 To 8, 1 To 8) As HeadState
Private mPending(1 To 8192) As QueuedEvent
Private mPendingCount As Long
Private mNextSequence As Long
Private mEpoch As String
Private mIdentity As String
Private mFolder As String
Private mOutbox As String
Private mMainLog As String
Private mBackLog As String
Private mLine1 As String
Private mLine2 As String
Private mReady As Boolean
Private mConnected As Boolean
Private mBlocked As Boolean
Private mProblem As String
Private mWarning As String
Private mExportProblem As String
Private mAuditProblem As String
Private mSourceIdentity As String
Private mPort As Integer
Private mGood(1 To 8, 1 To 8) As Boolean
' Session-only display metadata; never added to the persisted event/state schema.
Private mDisplayGood(1 To 8, 1 To 8) As Boolean
Private mDisplayLastRead(1 To 8, 1 To 8) As Date
Private mDiagnostic(1 To 8) As Boolean
Private mStates(1 To 8, 1 To 8) As String
Private mPortProblems(1 To 8) As String
Private mReadProblems(1 To 8, 1 To 8) As String
Private mLastAttempt As Double
Private mRetryDelay As Double
Private mRetryStarted As Boolean
Private mLastExport As Double
Private mExportStarted As Boolean
Private mLastRequest(1 To 8) As Double
Private mRequestStarted(1 To 8) As Boolean
Private mExportPending As Long
Private mExportUncertain As Long
Private mExportCountsKnown As Boolean
Private mLastPoll(1 To 8) As Double
Private mPollStarted(1 To 8) As Boolean
Private mLastAccepted(1 To 8, 1 To 8) As Double
Private mAcceptedStarted(1 To 8, 1 To 8) As Boolean
#If COUNTER_TEST Then
Private mTesting As Boolean
#End If

Private Function LogDirectory(ByVal value As String) As String
    If Len(value) < 3 Or InStr(value, vbCr) > 0 Or InStr(value, vbLf) > 0 Or InStr(value, "|") > 0 Then Err.Raise vbObjectError + 2501, , "Invalid log directory"
    If Left$(value, 2) <> "\\" And Mid$(value, 2, 2) <> ":\" Then Err.Raise vbObjectError + 2502, , "Log directory must be an absolute path"
    If Right$(value, 1) <> "\" Then value = value & "\"
    LogDirectory = value
End Function

Private Sub Audit(ByVal kind As String, ByVal port As Integer, ByVal head As Integer, ByVal detail As String)
    Dim problem As String
    If Not AuditWrite(mFolder, kind, port, head, detail, problem) Then mAuditProblem = problem
End Sub

Private Sub RecordPhase(ByVal port As Integer, ByVal phase As String, ByVal started As Double)
    PerfRecord port, phase, TickElapsed(started, TickMs())
End Sub

Private Function Persist(ByRef heads() As HeadState, ByRef pending() As QueuedEvent, ByVal pendingCount As Long, ByVal nextSequence As Long, ByRef problem As String) As Boolean
    Dim payload As String, started As Double
    started = TickMs()
    If SnapshotEncode(mIdentity, mEpoch, nextSequence, heads, pending, pendingCount, payload, problem) Then
        Persist = StoreSave(payload, problem)
    End If
    RecordPhase mPort, "state-save", started
End Function

Private Sub GapHead(ByRef value As HeadState, ByVal port As Integer, ByVal head As Integer, ByVal reason As String)
    Dim atUtc As Date
    atUtc = value.LastObservationUtc
    If atUtc = 0 Then atUtc = UtcNow()
    If Not value.GapOpen Then Audit "gap-open", port, head, reason & "; last API observation UTC=" & Format$(atUtc, "yyyy-mm-dd hh:nn:ss")
    EngineGap value, atUtc
    mGood(port, head) = False
    mDisplayGood(port, head) = False
End Sub

Private Sub GapAll(ByVal reason As String)
    Dim p As Integer, h As Integer
    For p = 1 To 8
        For h = 1 To 8
            GapHead mHeads(p, h), p, h, reason
        Next h
    Next p
End Sub

Private Sub StorageFailure(ByVal problem As String)
    mBlocked = True
    mProblem = "STATE SAVE FAILED - counters frozen: " & problem
    GapAll mProblem
    LinkDisplayStop
    LinkClose
    mConnected = False
    mLastAttempt = TickMs(): mRetryStarted = True: mRetryDelay = 10000#
End Sub

Private Sub ConnectionLost(ByVal reason As String)
    Dim problem As String
    mProblem = reason
    GapAll reason
    Erase mDisplayGood
    LinkDisplayStop
    LinkClose
    mConnected = False
    mLastAttempt = TickMs(): mRetryStarted = True
    If mRetryDelay < 5000# Then mRetryDelay = 5000#
    If Not Persist(mHeads, mPending, mPendingCount, mNextSequence, problem) Then StorageFailure problem
End Sub

Private Function BeginState(ByVal folder As String, ByVal mainLog As String, ByVal backLog As String, ByVal line1 As String, ByVal line2 As String, ByRef problem As String) As Boolean
    Dim payload As String, outcome As Integer, p As Integer, h As Integer, warning As String
    On Error GoTo Failed
    mFolder = folder: mOutbox = folder & "\outbox"
    EnsureFolder mFolder
    EnsureFolder mOutbox
    PerfStart mFolder
    Erase mLastPoll: Erase mPollStarted
    Erase mLastAccepted: Erase mAcceptedStarted
    mExportCountsKnown = False
    mMainLog = LogDirectory(mainLog): mBackLog = LogDirectory(backLog)
    mLine1 = line1: mLine2 = line2
    If mLine1 <> "E" Or mLine2 <> "F" Then Err.Raise vbObjectError + 2503, , "This build requires barmag.ini Line1=E and Line2=F"
    mIdentity = "NILIT-EF-LEGACY-1|E|F|" & VUNIQ_EXE & "|" & mMainLog & "|" & mBackLog
    If Not StoreOpen(folder, problem) Then Exit Function
    outcome = StoreLoad(payload, problem)
    If outcome < 0 Then StoreClose: Exit Function
    warning = problem
    If outcome = 1 Then
        If Not SnapshotDecode(mIdentity, payload, mEpoch, mNextSequence, mHeads, mPending, mPendingCount, problem) Then StoreClose: Exit Function
        For p = 1 To 8
            For h = 1 To 8
                ' An old write may or may not have reached Vuniq. Never replay an
                ' operator-maintenance clear from a previous process lifetime.
                If mHeads(p, h).PendingMaintenanceClear Then Audit "maintenance-write-uncertain", p, h, "Canceled replay after process restart"
                mHeads(p, h).PendingMaintenanceClear = False
            Next h
        Next p
        GapAll "NILIT restarted; downtime excluded"
    Else
        mEpoch = NewEpoch(): mNextSequence = 1
        mPendingCount = 0
        Audit "new-state", 0, 0, "First installation starts counters at zero; no legacy history imported"
    End If
    If Not Persist(mHeads, mPending, mPendingCount, mNextSequence, problem) Then StoreClose: Exit Function
    mWarning = warning
    Audit "startup", 0, 0, "NILIT Legacy Counter 1.0.8-ef; API observations are not proof of fresh RS232 data; " & warning
    mPort = 1: mReady = True: mRetryDelay = 5000#
    BeginState = True
    Exit Function
Failed:
    problem = Err.Description
    StoreClose
End Function

Public Function RuntimeStart(ByRef problem As String) As Boolean
    On Error GoTo Failed
    If Not FileExists(INI_FILE) Then Err.Raise vbObjectError + 2504, , "Cannot find " & INI_FILE
    If Not FileExists(App.Path & "\nilit-export.exe") Then Err.Raise vbObjectError + 2505, , "nilit-export.exe must be installed next to nilit.exe"
    RuntimeStart = BeginState(DefaultDataFolder(), IniValue(INI_FILE, "MainLogDir"), IniValue(INI_FILE, "BackLogDir"), IniValue(INI_FILE, "Line1"), IniValue(INI_FILE, "Line2"), problem)
    Exit Function
Failed:
    problem = Err.Description
End Function

Private Sub CopyHeads(ByRef source() As HeadState, ByRef destination() As HeadState)
    Dim p As Integer, h As Integer
    For p = 1 To 8
        For h = 1 To 8
            destination(p, h) = source(p, h)
        Next h
    Next p
End Sub

Private Function StagePending() As Boolean
    Dim i As Long, problem As String, emptyQueue(1 To 8192) As QueuedEvent
    If mPendingCount = 0 Then StagePending = True: Exit Function
    For i = 1 To mPendingCount
        If Not ExportStage(mOutbox, mEpoch, mPending(i), mLine1, mLine2, mMainLog, mBackLog, problem) Then
            mExportProblem = "Export staging pending: " & problem
            Exit Function
        End If
    Next i
    If Not Persist(mHeads, emptyQueue, 0, mNextSequence, problem) Then StorageFailure problem: Exit Function
    Erase mPending: mPendingCount = 0
    StagePending = True
End Function

Private Sub ServiceExport()
    Dim problem As String, started As Double, staged As Boolean
    If mExportStarted And mPendingCount = 0 Then
        If TickElapsed(mLastExport, TickMs()) < 15000# Then Exit Sub
    End If
    mExportStarted = True: mLastExport = TickMs()
    started = TickMs()
    staged = StagePending()
    RecordPhase 0, "export-stage", started
    If Not staged Then
        mExportCountsKnown = False
        Exit Sub
    End If
    mExportPending = 0
    mExportUncertain = 0
    mExportCountsKnown = True
    mExportProblem = ""
End Sub

Private Function ConnectIfDue() As Boolean
    Dim problem As String
    If mConnected Then ConnectIfDue = True: Exit Function
    If mRetryStarted Then
        If TickElapsed(mLastAttempt, TickMs()) < mRetryDelay Then Exit Function
    End If
    mRetryStarted = True: mLastAttempt = TickMs()
    If Not LinkOpen(VUNIQ_EXE, problem) Then
        mProblem = problem
        Audit "connect-failed", 0, 0, problem
        mRetryDelay = mRetryDelay * 2#
        If mRetryDelay > 30000# Then mRetryDelay = 30000#
        Exit Function
    End If
    If Not LinkDisplayStart(mDisplayLastRead, problem) Then
        mProblem = problem
        Audit "display-initialize-failed", 0, 0, problem
        LinkClose
        Exit Function
    End If
    Erase mDisplayGood
    mConnected = True: mRetryDelay = 5000#: mProblem = ""
    mSourceIdentity = LinkIdentity()
    Audit "connected", 0, 0, mSourceIdentity
    ConnectIfDue = True
End Function

Private Sub AddEvents(ByRef queue() As QueuedEvent, ByRef count As Long, ByRef nextSequence As Long, ByVal port As Integer, ByVal head As Integer, ByRef value As HeadState, ByRef events() As CounterEvent, ByVal eventCount As Long, ByVal localNow As Date)
    Dim i As Long
    For i = 1 To eventCount
        If count >= QUEUE_LIMIT Or nextSequence >= 2147483647 Then Err.Raise vbObjectError + 2506, , "Durable event queue is full; counter requires attention"
        count = count + 1
        With queue(count)
            .Sequence = nextSequence
            .Port = port: .Head = head
            .Kind = events(i).Kind: .Mode = events(i).Mode
            .Maintenance = events(i).Maintenance: .Minutes = events(i).Minutes
            .OccurredLocal = localNow: .HasGap = events(i).HasGap
            .WipingDate = value.WipingDate: .WipingTime = value.WipingTime
        End With
        nextSequence = nextSequence + 1
    Next i
End Sub

Private Sub ObservePort()
    Dim work(1 To 8, 1 To 8) As HeadState
    Dim queue(1 To 8192) As QueuedEvent
    Dim samples(1 To 8) As HeadSample, valid(1 To 8) As Boolean
    Dim states(1 To 8) As String, errors(1 To 8) As String
    Dim events(1 To 4) As CounterEvent, eventCount As Long
    Dim count As Long, sequence As Long, i As Long, h As Integer
    Dim supported As Boolean, healthy As Boolean, readOK As Boolean, commBefore As String, commAfter As String
    Dim problem As String, ignored As String, tick As Double, atUtc As Date, localNow As Date
    Dim hadGap(1 To 8) As Boolean, toPublish As HeadState, writeOK As Boolean, hasPriorGood As Boolean
    Dim retryHead(1 To 8) As Boolean, started As Double, checked As Boolean
    On Error GoTo Failed
    tick = TickMs()
    If mPollStarted(mPort) Then PerfRecord mPort, "poll-interval", TickElapsed(mLastPoll(mPort), tick)
    mLastPoll(mPort) = tick: mPollStarted(mPort) = True
    started = TickMs()
    checked = LinkCheckIdentity(problem)
    RecordPhase mPort, "identity-check", started
    If Not checked Then ConnectionLost problem: Exit Sub
    For h = 1 To 8
        If mDisplayGood(mPort, h) Then hasPriorGood = True
        retryHead(h) = mHeads(mPort, h).GapOpen
    Next h
    started = TickMs()
    checked = LinkDisplayReading(mPort, hasPriorGood, problem)
    If checked Then checked = LinkDisplayRetryStart(mPort, retryHead, problem)
    RecordPhase mPort, "read-mark", started
    If Not checked Then ConnectionLost problem: Exit Sub
    CopyHeads mHeads, work
    count = mPendingCount: sequence = mNextSequence
    For i = 1 To count: queue(i) = mPending(i): Next i
    started = TickMs()
    readOK = LinkReadComm(mPort, supported, healthy, commBefore, problem)
    RecordPhase mPort, "comm-before", started
    mDiagnostic(mPort) = supported
    If Not readOK Then GoTo BadPort
    If supported And Not healthy Then problem = "Vuniq station communication error": GoTo BadPort
    started = TickMs()
    For h = 1 To 8
        valid(h) = LinkReadHead(mPort, h, samples(h), states(h), errors(h))
    Next h
    RecordPhase mPort, "head-read", started
    started = TickMs()
    readOK = LinkReadComm(mPort, supported, healthy, commAfter, problem)
    RecordPhase mPort, "comm-after", started
    mDiagnostic(mPort) = supported
    If Not readOK Then GoTo BadPort
    If supported And Not healthy Then problem = "Vuniq station communication error after read": GoTo BadPort
    started = TickMs()
    checked = LinkCheckIdentity(problem)
    RecordPhase mPort, "identity-check", started
    If Not checked Then ConnectionLost problem: Exit Sub
    tick = TickMs(): atUtc = UtcNow(): localNow = Now
    mPortProblems(mPort) = ""
    For h = 1 To 8
        If valid(h) Then
            mReadProblems(mPort, h) = ""
            hadGap(h) = work(mPort, h).GapOpen
            EngineObserve work(mPort, h), samples(h), tick, atUtc, localNow, 30000#, 0, 0, 0, events, eventCount
            AddEvents queue, count, sequence, mPort, h, work(mPort, h), events, eventCount, localNow
        Else
            If mReadProblems(mPort, h) <> errors(h) Then Audit "head-unavailable", mPort, h, errors(h) & "; states=" & states(h)
            mReadProblems(mPort, h) = errors(h)
            If Len(mPortProblems(mPort)) = 0 Then mPortProblems(mPort) = errors(h)
            GapHead work(mPort, h), mPort, h, errors(h)
        End If
    Next h
    GoTo Commit
BadPort:
    started = TickMs()
    checked = LinkCheckIdentity(ignored)
    RecordPhase mPort, "identity-check", started
    If Not checked Then ConnectionLost ignored: Exit Sub
    mPortProblems(mPort) = problem
    For h = 1 To 8
        valid(h) = False
        GapHead work(mPort, h), mPort, h, problem
    Next h
    Audit "port-unavailable", mPort, 0, problem & "; before=" & commBefore & "; after=" & commAfter
Commit:
    If Not Persist(work, queue, count, sequence, problem) Then StorageFailure problem: Exit Sub
    CopyHeads work, mHeads
    mPendingCount = count: mNextSequence = sequence
    For i = 1 To count: mPending(i) = queue(i): Next i
    started = TickMs()
    For h = 1 To 8
        If valid(h) Then
            If mAcceptedStarted(mPort, h) Then PerfRecord mPort, "accepted-interval-h" & CStr(h), TickElapsed(mLastAccepted(mPort, h), tick)
            mLastAccepted(mPort, h) = tick: mAcceptedStarted(mPort, h) = True
        End If
        mGood(mPort, h) = valid(h) And mHeads(mPort, h).Initialized And mHeads(mPort, h).CandidateCount = 0
        If valid(h) Then
            If hadGap(h) Then Audit "gap-close", mPort, h, "API observations resumed; excluded interval begins " & Format$(mHeads(mPort, h).GapStartUtc, "yyyy-mm-dd hh:nn:ss") & " UTC"
            If states(h) <> mStates(mPort, h) Then
                Audit "api-states", mPort, h, states(h)
                mStates(mPort, h) = states(h)
            End If
            If mHeads(mPort, h).Initialized And mHeads(mPort, h).NeedsPublish Then
                toPublish = mHeads(mPort, h)
                ' Do not clear an operator value during a pending transition or
                ' after winding has stopped. A failed clear is not retried.
                If (samples(h).WindingRaw And 6&) = 0 Then toPublish.PendingMaintenanceClear = False
                writeOK = LinkWriteHead(mPort, h, toPublish, problem)
                mHeads(mPort, h).PendingMaintenanceClear = False
                If writeOK Then
                    mHeads(mPort, h).NeedsPublish = False
                Else
                    RecordPhase mPort, "head-publish", started
                    Audit "publish-failed", mPort, h, problem
                    ConnectionLost problem
                    Exit Sub
                End If
            End If
        End If
    Next h
    RecordPhase mPort, "head-publish", started
    For h = 1 To 8
        If valid(h) Then mDisplayLastRead(mPort, h) = localNow
        mDisplayGood(mPort, h) = valid(h) And mHeads(mPort, h).Initialized And _
            mHeads(mPort, h).HasBaseline And Not mHeads(mPort, h).GapOpen And _
            mHeads(mPort, h).CandidateCount = 0 And Not mHeads(mPort, h).NeedsPublish
    Next h
    started = TickMs()
    checked = LinkDisplayPort(mPort, mDisplayGood, mDisplayLastRead, problem)
    RecordPhase mPort, "display-publish", started
    If Not checked Then
        Audit "display-publish-failed", mPort, 0, problem
        ConnectionLost problem
        Exit Sub
    End If
    started = TickMs()
    checked = LinkDisplayRetryEnd(mPort, problem)
    RecordPhase mPort, "retry-end", started
    If Not checked Then ConnectionLost problem: Exit Sub
    If Not mRequestStarted(mPort) Or TickElapsed(mLastRequest(mPort), TickMs()) >= 60000# Then
        mRequestStarted(mPort) = True: mLastRequest(mPort) = TickMs()
        started = TickMs()
        checked = LinkRequestStatus(mPort, problem)
        RecordPhase mPort, "status-request", started
        If Not checked Then Audit "status-request-failed", mPort, 0, problem
    End If
    If mPort = 8 Then
        started = TickMs()
        checked = LinkWriteSummary(mHeads, problem)
        RecordPhase mPort, "summary-publish", started
        If Not checked Then Audit "summary-write-failed", 0, 0, problem
    End If
    mPort = mPort + 1
    If mPort > 8 Then mPort = 1
    Exit Sub
Failed:
    problem = Err.Description
    StorageFailure problem
End Sub

Public Sub RuntimeStep()
    Dim problem As String, started As Double, exportStarted As Double
    If Not mReady Then Exit Sub
    started = TickMs()
    On Error GoTo Failed
    If mBlocked Then
        If TickElapsed(mLastAttempt, TickMs()) < 10000# Then GoTo Done
        mLastAttempt = TickMs()
        If Not Persist(mHeads, mPending, mPendingCount, mNextSequence, problem) Then GoTo Done
        mBlocked = False: mProblem = ""
        Audit "storage-recovered", 0, 0, "Counters resume from last committed observations"
    End If
    exportStarted = TickMs()
    ServiceExport
    RecordPhase 0, "export-service", exportStarted
    If mBlocked Then GoTo Done
    If Not ConnectIfDue() Then GoTo Done
    ObservePort
Done:
    RecordPhase 0, "runtime-step", started
    PerfFlush
    Exit Sub
Failed:
    problem = Err.Description
    StorageFailure problem
    Resume Done
End Sub

Public Function RuntimeStatus() As String
    Dim p As Integer, h As Integer, good As Long, initialized As Long, diagnostics As Long, gaps As Long, capped As Long
    For p = 1 To 8
        If mDiagnostic(p) Then diagnostics = diagnostics + 1
        For h = 1 To 8
            If mHeads(p, h).Initialized Then initialized = initialized + 1
            If mGood(p, h) Then good = good + 1
            If mHeads(p, h).HasGap Then gaps = gaps + 1
            If EngineMinutes(mHeads(p, h).ElapsedMs) >= 19679 Then capped = capped + 1
        Next h
    Next p
    RuntimeStatus = "NILIT Counter 1.0.8-ef" & vbCrLf & "Observed: " & CStr(good) & "/64    Initialized: " & CStr(initialized) & "/64" & vbCrLf
    RuntimeStatus = RuntimeStatus & "Display timestamps: accepted API reads in this session only" & vbCrLf
    RuntimeStatus = RuntimeStatus & "Communication diagnostic available: " & CStr(diagnostics) & "/8 ports" & vbCrLf
    RuntimeStatus = RuntimeStatus & "Segments with unknown time excluded: " & CStr(gaps) & "/64" & vbCrLf
    If mExportCountsKnown Then
        RuntimeStatus = RuntimeStatus & "SAP queued: " & CStr(mExportPending + mPendingCount) & "    Uncertain delivery: " & CStr(mExportUncertain) & vbCrLf
    Else
        RuntimeStatus = RuntimeStatus & "SAP queued: unknown (local pending: " & CStr(mPendingCount) & ")    Uncertain delivery: unknown" & vbCrLf
    End If
    If mBlocked Then
        RuntimeStatus = RuntimeStatus & "FROZEN - storage problem" & vbCrLf
    ElseIf Not mConnected Then
        RuntimeStatus = RuntimeStatus & "RECONNECTING - counters frozen" & vbCrLf
    ElseIf good < 64 Then
        RuntimeStatus = RuntimeStatus & "Some heads are initializing or unavailable; their counters are frozen" & vbCrLf
    Else
        RuntimeStatus = RuntimeStatus & "Counting API observations; RS232 freshness is not certified" & vbCrLf
    End If
    If Len(mProblem) > 0 Then RuntimeStatus = RuntimeStatus & mProblem & vbCrLf
    If Len(mWarning) > 0 Then RuntimeStatus = RuntimeStatus & mWarning & vbCrLf
    If Len(mExportProblem) > 0 Then RuntimeStatus = RuntimeStatus & mExportProblem & vbCrLf
    If Len(mAuditProblem) > 0 Then RuntimeStatus = RuntimeStatus & "AUDIT ERROR: " & mAuditProblem & vbCrLf
    If Len(PerfProblem()) > 0 Then RuntimeStatus = RuntimeStatus & "TIMING DIAGNOSTIC: " & PerfProblem() & vbCrLf
    For p = 1 To 8
        If Len(mPortProblems(p)) > 0 Then RuntimeStatus = RuntimeStatus & "Port " & CStr(p) & " UNKNOWN: " & mPortProblems(p) & vbCrLf
    Next p
    If capped > 0 Then RuntimeStatus = RuntimeStatus & "Display capped at 327:59 for " & CStr(capped) & " heads; full durations retained in state/logs" & vbCrLf
End Function

Public Function RuntimeDataFolder() As String
    RuntimeDataFolder = mFolder
End Function

Public Sub RuntimeStop()
    Dim problem As String
    On Error Resume Next
    If mReady Then
        GapAll "NILIT closed"
        If Not Persist(mHeads, mPending, mPendingCount, mNextSequence, problem) Then Audit "shutdown-save-failed", 0, 0, problem
        Audit "shutdown", 0, 0, "No Vuniq stop or global RemoveAllItems was requested"
    End If
    LinkDisplayStop
    LinkClose
    StoreClose
    PerfStop
    ReleaseWorkerHandle
    ReleaseCounter
    mReady = False
End Sub

#If COUNTER_TEST Then
Public Function RuntimeTestStart(ByVal folder As String, ByVal mainLog As String, ByVal backLog As String, ByRef problem As String, Optional ByVal line1 As String = "E", Optional ByVal line2 As String = "F") As Boolean
    Erase mHeads: Erase mPending: Erase mGood: Erase mDiagnostic: Erase mStates
    Erase mDisplayGood: Erase mDisplayLastRead
    Erase mPortProblems: Erase mReadProblems
    Erase mRequestStarted: Erase mLastRequest
    mReady = False: mConnected = False: mBlocked = False: mRetryStarted = False
    mExportStarted = False: mPendingCount = 0: mWarning = "": mExportProblem = "": mProblem = "": mAuditProblem = ""
    mTesting = True
    RuntimeTestStart = BeginState(folder, mainLog, backLog, line1, line2, problem)
End Function
Public Sub RuntimeTestAttached()
    Dim problem As String
    If Not LinkDisplayStart(mDisplayLastRead, problem) Then Err.Raise vbObjectError + 2507, , problem
    Erase mDisplayGood
    mConnected = True
End Sub
Public Sub RuntimeTestDisplay(ByVal port As Integer, ByVal head As Integer, ByRef quality As Boolean, ByRef lastRead As Date)
    quality = mDisplayGood(port, head)
    lastRead = mDisplayLastRead(port, head)
End Sub
Public Sub RuntimeTestPollPort(ByVal port As Integer)
    mPort = port
    ObservePort
End Sub
Public Sub RuntimeTestHead(ByVal port As Integer, ByVal head As Integer, ByRef value As HeadState)
    value = mHeads(port, head)
End Sub
Public Function RuntimeTestStage() As Boolean
    RuntimeTestStage = StagePending()
End Function
Public Sub RuntimeTestExportService()
    mExportStarted = False
    ServiceExport
End Sub
Public Function RuntimeTestEpoch() As String
    RuntimeTestEpoch = mEpoch
End Function
Public Function RuntimeTestSequence() As Long
    RuntimeTestSequence = mNextSequence - 1
End Function
Public Function RuntimeTestPending() As Long
    RuntimeTestPending = mPendingCount
End Function
Public Function RuntimeTestBlocked() As Boolean
    RuntimeTestBlocked = mBlocked
End Function
#End If
