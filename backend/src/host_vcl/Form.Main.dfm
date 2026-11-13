object MainForm: TMainForm
  Left = 0
  Top = 0
  Caption = 'IPTVPlay - Dev Host'
  ClientHeight = 520
  ClientWidth = 760
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object pnlTop: TPanel
    Left = 0
    Top = 0
    Width = 760
    Height = 76
    Align = alTop
    BevelOuter = bvNone
    TabOrder = 0
    DesignSize = (
      760
      76)
    object lblPort: TLabel
      Left = 264
      Top = 16
      Width = 22
      Height = 15
      Caption = 'Port'
    end
    object lblStatus: TLabel
      Left = 440
      Top = 16
      Width = 44
      Height = 15
      Caption = 'Stopped'
    end
    object btnStart: TButton
      Left = 16
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Start'
      TabOrder = 0
      OnClick = btnStartClick
    end
    object btnStop: TButton
      Left = 97
      Top = 11
      Width = 75
      Height = 25
      Caption = 'Stop'
      TabOrder = 1
      OnClick = btnStopClick
    end
    object btnRefresh: TButton
      Left = 178
      Top = 11
      Width = 80
      Height = 25
      Caption = 'Refresh all'
      TabOrder = 2
      OnClick = btnRefreshClick
    end
    object btnOpenClient: TButton
      Left = 600
      Top = 11
      Width = 145
      Height = 25
      Anchors = [akTop, akRight]
      Caption = 'Open client in browser'
      TabOrder = 4
      OnClick = btnOpenClientClick
    end
    object edPort: TEdit
      Left = 294
      Top = 13
      Width = 73
      Height = 23
      TabOrder = 3
      Text = '7777'
    end
    object chkProxy: TCheckBox
      Left = 16
      Top = 48
      Width = 380
      Height = 17
      Caption = 'Stream proxy (relay video through this server, e.g. when abroad)'
      TabOrder = 5
      OnClick = chkProxyClick
    end
  end
  object memLog: TMemo
    Left = 0
    Top = 49
    Width = 760
    Height = 471
    Align = alClient
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -12
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    ReadOnly = True
    ScrollBars = ssBoth
    TabOrder = 1
  end
end
