Attribute VB_Name = "CounterEngine"
Option Explicit

Private Const TICK_MODULUS As Double = 4294967296#
Private Const MAX_LONG_VALUE As Double = 2147483647#

' Pure state engine: callers supply a complete, validated observation. A
' successful API call is not evidence of fresh physical RS232/PLC data.
Public Sub EngineGap(ByRef head As HeadState, ByVal atUtc As Date)
    If Not head.GapOpen Then head.GapStartUtc = atUtc
    head.GapOpen = True
    head.HasBaseline = False
    head.LastSampleMode = 0
    head.CandidateMode = 0
    head.CandidateCount = 0
    If head.Initialized Then
        head.HasGap = True
        head.GapBeforePending = True
    End If
    head.NeedsPublish = True
End Sub

Public Function EngineMinutes(ByVal milliseconds As Double) As Long
    If milliseconds <= 0# Then Exit Function
    If milliseconds / 60000# >= MAX_LONG_VALUE Then
        EngineMinutes = 2147483647
    Else
        EngineMinutes = CLng(Fix(milliseconds / 60000#))
    End If
End Function

Public Function EngineHHMM(ByVal milliseconds As Double) As Long
    Dim minutes As Long
    minutes = EngineMinutes(milliseconds)
    ' 327:59 is the largest valid HHMM representable by the legacy Integer.
    If minutes >= 19679 Then
        EngineHHMM = 32759
    Else
        EngineHHMM = (minutes \ 60) * 100& + (minutes Mod 60)
    End If
End Function

Private Function InLegacyClean(ByVal wipeDay As Long, ByVal wipeTime As Long, _
        ByVal localNow As Date, ByVal thresholdMinutes As Long) As Boolean
    Dim wipeMinutes As Long
    Dim nowMinutes As Long
    ' Deliberately preserve the original same-day/subtraction semantics.
    ' This predicate is a business rule, never a source of elapsed duration.
    If wipeDay = 0 Or wipeDay <> Day(localNow) Then Exit Function
    wipeMinutes = (wipeTime \ 100) * 60& + (wipeTime Mod 100)
    nowMinutes = CLng(Hour(localNow)) * 60& + CLng(Minute(localNow))
    InLegacyClean = ((wipeMinutes - nowMinutes) < thresholdMinutes)
End Function

Private Sub PushEvent(ByRef events() As CounterEvent, ByRef eventCount As Long, _
        ByVal kind As String, ByVal mode As Integer, ByVal maintenance As Long, _
        ByVal elapsedMs As Double, ByVal atUtc As Date, ByVal hasGap As Boolean)
    eventCount = eventCount + 1
    With events(eventCount)
        .Kind = kind
        .Mode = mode
        .Maintenance = maintenance
        .Minutes = EngineMinutes(elapsedMs)
        .OccurredUtc = atUtc
        .HasGap = hasGap
    End With
End Sub

Private Sub AdoptMode(ByRef head As HeadState, ByVal newMode As Integer, _
        ByVal winding As Long, ByVal atUtc As Date, _
        ByRef events() As CounterEvent, ByRef eventCount As Long)
    Dim boundaryGap As Boolean
    boundaryGap = head.GapBeforePending
    If head.Initialized Then
        If newMode = ENGINE_MODE_BLUE Then
            ' Legacy blue entry logs the preceding color WITHOUT finish suffix.
            PushEvent events, eventCount, "blue-previous", head.Mode, head.Maintenance, head.ElapsedMs, atUtc, head.HasGap
        Else
            PushEvent events, eventCount, "finish", head.Mode, head.Maintenance, head.ElapsedMs, atUtc, head.HasGap
        End If
    End If
    head.Initialized = True
    head.Mode = newMode
    head.ElapsedMs = 0#
    head.CandidateMode = 0
    head.CandidateCount = 0
    head.HasGap = boundaryGap
    head.GapBeforePending = False
    head.NeedsPublish = True
    If newMode = ENGINE_MODE_BLUE Then
        PushEvent events, eventCount, "maintenance", newMode, head.Maintenance, 0#, atUtc, boundaryGap
    Else
        PushEvent events, eventCount, "start", newMode, head.Maintenance, 0#, atUtc, boundaryGap
    End If
    If newMode = ENGINE_MODE_GREEN Then
        head.WorkingWinding = winding
        head.PendingMaintenanceClear = True
    Else
        head.PendingMaintenanceClear = False
        If newMode = ENGINE_MODE_RED Then head.StopMs = 0#
    End If
End Sub

Public Sub EngineObserve(ByRef head As HeadState, ByRef sample As HeadSample, _
        ByVal tickMs As Double, ByVal atUtc As Date, ByVal localNow As Date, _
        ByVal maxIntervalMs As Double, ByVal blinkGreenSP As Long, _
        ByVal blinkRedSP As Long, ByVal yellowSP As Long, _
        ByRef events() As CounterEvent, ByRef eventCount As Long)
    Dim observedMode As Integer
    Dim winding As Long
    Dim intervalMs As Double
    Dim canAccumulate As Boolean
    Dim oldMinutes As Long
    Dim nextBlink As Integer

    eventCount = 0
    ' Invalid restored state must be rejected, never turned into a blank log.
    If head.Initialized Then
        If head.Mode < ENGINE_MODE_GREEN Or head.Mode > ENGINE_MODE_BLUE Then
            Err.Raise vbObjectError + 1601, "CounterEngine", "Invalid initialized mode"
        End If
        If head.ElapsedMs < 0# Or head.StopMs < 0# Then
            Err.Raise vbObjectError + 1602, "CounterEngine", "Negative counter duration"
        End If
    End If
    If tickMs < 0# Or tickMs >= TICK_MODULUS Or maxIntervalMs <= 0# Or maxIntervalMs >= 2147483648# Then
        EngineGap head, atUtc
        Exit Sub
    End If
    If head.HasBaseline Then
        If head.LastTickMs < 0# Or head.LastTickMs >= TICK_MODULUS Then
            EngineGap head, atUtc
        Else
            intervalMs = tickMs - head.LastTickMs
            If intervalMs < 0# Then intervalMs = intervalMs + TICK_MODULUS
            If intervalMs > maxIntervalMs Then EngineGap head, atUtc
        End If
    End If
    If Not head.HasBaseline Then
        intervalMs = 0#
        head.CandidateMode = 0
        head.CandidateCount = 0
        head.LastSampleMode = 0
        If head.Initialized Then
            head.HasGap = True
            head.GapBeforePending = True
            head.NeedsPublish = True
        End If
    End If

    head.Maintenance = sample.Maintenance
    If sample.WipingDate <> 0 Then head.WipingDate = sample.WipingDate
    If sample.WipingTime <> 0 Then head.WipingTime = sample.WipingTime
    winding = sample.WindingRaw And 6&
    If winding <> 0 Then
        observedMode = ENGINE_MODE_GREEN
    ElseIf head.Maintenance <> 0 Then
        observedMode = ENGINE_MODE_BLUE
    ElseIf InLegacyClean(head.WipingDate, head.WipingTime, localNow, yellowSP) Then
        observedMode = ENGINE_MODE_YELLOW
    Else
        observedMode = ENGINE_MODE_RED
    End If

    canAccumulate = head.Initialized And head.HasBaseline And _
        (head.Mode = observedMode) And (head.LastSampleMode = observedMode) And _
        (head.CandidateCount = 0)
    If head.Initialized And head.Mode = observedMode Then
        If canAccumulate Then
            oldMinutes = EngineMinutes(head.ElapsedMs)
            head.ElapsedMs = head.ElapsedMs + intervalMs
            If observedMode = ENGINE_MODE_RED Then head.StopMs = head.StopMs + intervalMs
            If EngineMinutes(head.ElapsedMs) <> oldMinutes Then head.NeedsPublish = True
        End If
        head.CandidateMode = 0
        head.CandidateCount = 0
        head.GapBeforePending = False
        If observedMode = ENGINE_MODE_GREEN And head.WorkingWinding <> winding Then
            PushEvent events, eventCount, "auto", ENGINE_MODE_AUTO, head.Maintenance, 0#, atUtc, head.HasGap
            head.WorkingWinding = winding
        End If
    Else
        If observedMode = ENGINE_MODE_BLUE Then
            AdoptMode head, observedMode, winding, atUtc, events, eventCount
        Else
            If head.CandidateMode = observedMode Then
                head.CandidateCount = head.CandidateCount + 1
            Else
                head.CandidateMode = observedMode
                head.CandidateCount = 1
            End If
            If head.CandidateCount >= 2 Then AdoptMode head, observedMode, winding, atUtc, events, eventCount
        End If
    End If

    ' Blinking follows the observed legacy branch, including its debounce read.
    nextBlink = 0
    If observedMode = ENGINE_MODE_GREEN Then
        If InLegacyClean(head.WipingDate, head.WipingTime, localNow, blinkGreenSP) Then nextBlink = 1
    ElseIf observedMode = ENGINE_MODE_RED Then
        If EngineMinutes(head.StopMs) >= blinkRedSP Then nextBlink = 1
    End If
    If head.Blink <> nextBlink Then
        head.Blink = nextBlink
        head.NeedsPublish = True
    End If
    head.LastTickMs = tickMs
    head.LastSampleMode = observedMode
    head.LastObservationUtc = atUtc
    head.HasBaseline = True
    head.GapOpen = False
End Sub
