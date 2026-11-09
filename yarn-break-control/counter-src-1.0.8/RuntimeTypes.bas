Attribute VB_Name = "RuntimeTypes"
Option Explicit

Public Type QueuedEvent
    Sequence As Long
    Port As Integer
    Head As Integer
    Kind As String
    Mode As Integer
    Maintenance As Long
    Minutes As Long
    OccurredLocal As Date
    HasGap As Boolean
    WipingDate As Long
    WipingTime As Long
End Type
