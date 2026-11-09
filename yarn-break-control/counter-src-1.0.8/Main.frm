VERSION 5.00
Begin VB.Form MainForm
   Caption         =   "Nilit - Counter 1.0.8-ef"
   ClientHeight    =   3915
   ClientLeft      =   60
   ClientTop       =   345
   ClientWidth     =   7575
   ScaleHeight     =   3915
   ScaleWidth      =   7575
   StartUpPosition =   2
   Begin VB.Timer Timer1
      Interval        =   1000
      Left            =   600
      Top             =   2640
   End
   Begin VB.Label timeLabel
      Height          =   375
      Left            =   3000
      TabIndex        =   0
      Top             =   120
      Width           =   2200
   End
   Begin VB.TextBox statusLabel
      Height          =   2700
      Left            =   240
      Locked          =   -1
      MultiLine       =   -1
      ScrollBars      =   2
      TabIndex        =   1
      Top             =   600
      Width           =   7100
   End
   Begin VB.CommandButton DataButton
      Caption         =   "Open local history"
      Height          =   400
      Left            =   240
      TabIndex        =   2
      Top             =   3375
      Width           =   2400
   End
End
Attribute VB_Name = "MainForm"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
Option Explicit

Private Sub Form_Load()
    timeLabel.Caption = Time$
    statusLabel.Text = RuntimeStatus()
End Sub

Private Sub Form_Unload(Cancel As Integer)
    Timer1.Enabled = False
    RuntimeStop
End Sub

Private Sub Timer1_Timer()
    On Error GoTo Failed
    Timer1.Enabled = False
    RuntimeStep
    timeLabel.Caption = Time$
    statusLabel.Text = RuntimeStatus()
    Timer1.Enabled = True
    Exit Sub
Failed:
    statusLabel.Text = "COUNTER ERROR: " & Err.Description
    Timer1.Enabled = True
End Sub

Private Sub DataButton_Click()
    On Error GoTo Failed
    Shell "explorer.exe " & Chr$(34) & RuntimeDataFolder() & Chr$(34), vbNormalFocus
    Exit Sub
Failed:
    MsgBox Err.Description, vbExclamation, "NILIT Counter"
End Sub
