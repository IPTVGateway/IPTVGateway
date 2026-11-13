unit Form.Main;

{ Dev cockpit. Owns one TAppContext; Start/Stop buttons, a port box, a "refresh
  all now" button and a log memo. The log proc marshals to the UI thread. }

interface

uses
  // RTL
  Winapi.Windows,
  Winapi.Messages,
  Winapi.ShellAPI,
  System.SysUtils,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  // Own units
  IPTV.App.Config,
  IPTV.App.Runner,
  IPTV.App.Context;

type
  /// Dev cockpit form: start/stop the runner, refresh, proxy toggle and a log memo.
  TMainForm = class(TForm)
    pnlTop: TPanel;
    btnStart: TButton;
    btnStop: TButton;
    btnRefresh: TButton;
    btnOpenClient: TButton;
    edPort: TEdit;
    lblPort: TLabel;
    lblStatus: TLabel;
    memLog: TMemo;
    chkProxy: TCheckBox;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure btnRefreshClick(Sender: TObject);
    procedure btnOpenClientClick(Sender: TObject);
    procedure chkProxyClick(Sender: TObject);
  private
    FRunner: TAppRunner;   // dev host controls the same worker thread the service uses
    FSyncingProxy: Boolean; // guard: setting chkProxy.Checked in code must not re-fire the handler
    /// config.json next to the exe.
    function ConfigPath: string;
    /// Appends a line to the memo (marshalled to the UI thread).
    procedure Log(const AMsg: string);
    /// Enables the buttons and sets the status label for the running state.
    procedure UpdateButtons;
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

const
  // the log memo is cleared once it holds more lines than this
  cMaxLogMemoLines = 2000;

function TMainForm.ConfigPath: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + cConfigFileName;
end;

procedure TMainForm.FormCreate(Sender: TObject);
var
  lConfig: TAppConfig;
begin
  lConfig := TAppConfig.Load(ConfigPath);
  edPort.Text := lConfig.HttpPort.ToString;
  FSyncingProxy := True;
  chkProxy.Checked := lConfig.ProxyStreams;
  FSyncingProxy := False;
  UpdateButtons;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if Assigned(FRunner) then
    FRunner.StopAndWait; // joins the worker — no more log lines are queued after this
  FreeAndNil(FRunner);
  // Flush any log closures queued during Stop NOW, while memLog still exists. They
  // were posted via TThread.Queue(nil, …) and would otherwise run after the form is
  // freed and touch a destroyed TMemo (access violation on exit).
  CheckSynchronize(0);
end;

procedure TMainForm.Log(const AMsg: string);
begin
  TThread.Queue(nil,
    procedure
    begin
      // cap the memo so a long-running dev session (daily refresh, relay logs) can't
      // grow it unbounded
      if memLog.Lines.Count > cMaxLogMemoLines then
        memLog.Lines.Clear;
      memLog.Lines.Add(Format('%s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), AMsg]));
    end);
end;

procedure TMainForm.UpdateButtons;
begin
  btnStart.Enabled := FRunner = nil;
  btnStop.Enabled := FRunner <> nil;
  btnRefresh.Enabled := FRunner <> nil;
  edPort.Enabled := FRunner = nil;
  if FRunner <> nil then
    lblStatus.Caption := 'Running on port ' + edPort.Text
  else
    lblStatus.Caption := 'Stopped';
end;

procedure TMainForm.btnStartClick(Sender: TObject);
var
  lConfig: TAppConfig;
begin
  if Assigned(FRunner) then
    Exit; // already running — guard against a reentrant click leaking the runner/port
  lConfig := TAppConfig.Load(ConfigPath);
  lConfig.HttpPort := StrToIntDef(edPort.Text, lConfig.HttpPort);
  FRunner := TAppRunner.Create(lConfig, Log);  // worker thread does the real work
  Log('Starting...');
  UpdateButtons;
end;

procedure TMainForm.btnStopClick(Sender: TObject);
begin
  if Assigned(FRunner) then
    FRunner.StopAndWait;
  FreeAndNil(FRunner);
  Log('Stopped.');
  UpdateButtons;
end;

procedure TMainForm.btnRefreshClick(Sender: TObject);
var
  lContext: TAppContext;
begin
  if (FRunner = nil) or (not FRunner.Started) then
    Exit;
  // Route through SpawnBackground so the context's FBgOps counter tracks it and
  // Stop WAITS for the refresh to finish before freeing the store/ingest — a raw
  // detached thread here would let Stop free them mid-refresh (use-after-free).
  lContext := FRunner.Context;
  lContext.SpawnBackground(
    procedure
    begin
      lContext.Ingest.RefreshAll;
    end);
end;

procedure TMainForm.btnOpenClientClick(Sender: TObject);
var
  lConfig: TAppConfig;
begin
  // open the React client (Vite dev server by default) in the default browser
  lConfig := TAppConfig.Load(ConfigPath);
  ShellExecute(Handle, 'open', PChar(lConfig.ClientUrl), nil, nil, SW_SHOWNORMAL);
end;

procedure TMainForm.chkProxyClick(Sender: TObject);
var
  lConfig: TAppConfig;
begin
  if FSyncingProxy then
    Exit;
  if (FRunner <> nil) and FRunner.Started then
  begin
    // apply live: starts/stops the relay and persists to config.json
    lConfig := FRunner.Context.Config;
    FRunner.Context.UpdateSettings(lConfig.RefreshHour, lConfig.RefreshMinute, chkProxy.Checked, lConfig.ProxyPort);
    Log(Format('Stream proxy %s (port %d).',
      [BoolToStr(chkProxy.Checked, True), lConfig.ProxyPort]));
  end
  else
  begin
    // not running: persist the choice so the next Start picks it up
    lConfig := TAppConfig.Load(ConfigPath);
    lConfig.ProxyStreams := chkProxy.Checked;
    lConfig.Save(ConfigPath);
    Log(Format('Stream proxy %s saved to config (applies on Start).',
      [BoolToStr(chkProxy.Checked, True)]));
  end;
end;

end.
