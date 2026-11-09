Attribute VB_Name = "CounterTypes"
Option Explicit

Public Const ENGINE_MODE_GREEN As Integer = 1
Public Const ENGINE_MODE_RED As Integer = 2
Public Const ENGINE_MODE_YELLOW As Integer = 3
Public Const ENGINE_MODE_BLUE As Integer = 4
Public Const ENGINE_MODE_AUTO As Integer = 5

Public Type HeadState
    Initialized As Boolean
    Mode As Integer
    ElapsedMs As Double
    StopMs As Double
    WorkingWinding As Long
    Maintenance As Long
    WipingDate As Long
    WipingTime As Long
    Blink As Integer
    CandidateMode As Integer
    CandidateCount As Integer
    HasBaseline As Boolean
    LastTickMs As Double
    LastObservationUtc As Date
    GapStartUtc As Date
    GapOpen As Boolean
    HasGap As Boolean
    NeedsPublish As Boolean
    PendingMaintenanceClear As Boolean
    LastSampleMode As Integer
    GapBeforePending As Boolean
End Type

Public Type HeadSample
    Maintenance As Long
    WipingDate As Long
    WipingTime As Long
    WindingRaw As Long
End Type

Public Type CounterEvent
    Kind As String
    Mode As Integer
    Maintenance As Long
    Minutes As Long
    OccurredUtc As Date
    HasGap As Boolean
End Type
