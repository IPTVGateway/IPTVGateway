unit IPTV.App.Runner;

{ The application's dedicated worker thread.

  Best practice for a service: never run the real work on the host's control
  thread. The host (Windows service, systemd daemon, or the VCL dev form) only
  *controls* this runner — create it to start, SignalStop/StopAndWait to stop.
  The runner owns the TAppContext for its whole lifetime and runs it on its own
  thread, so the host stays free to answer control requests immediately.

  The worker creates the context up-front (so Context is reachable right away)
  and does the heavy Start (open DB, bind HTTP, launch scheduler) on its own
  thread, then idles until signalled to stop. }

interface

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  // Own units
  IPTV.App.Config,
  IPTV.App.Context,
  IPTV.Ingest.Service;

type
  /// Dedicated worker thread that owns and runs the TAppContext.
  TAppRunner = class(TThread)
  private
    FConfig: TAppConfig;
    FLog: TLogProc;
    FContext: TAppContext;
    FStop: TEvent;
    FStartDone: TEvent; // set once Start has succeeded or failed
    FStarted: Boolean;
    FStartError: string;
  protected
    procedure Execute; override;
  public
    /// AConfigPath is forwarded to TAppContext: where settings are loaded/saved
    /// (empty => config.json next to the exe). The Windows Service passes a
    /// writable ProgramData path.
    constructor Create(const AConfig: TAppConfig; const ALog: TLogProc = nil;
      const AConfigPath: string = '');
    destructor Destroy; override;
    /// Ask the worker to wind down (non-blocking).
    procedure SignalStop;
    /// SignalStop + block until fully stopped.
    procedure StopAndWait;
    /// Valid once created; check Started before use.
    property Context: TAppContext read FContext;
    /// True while the context is started and running.
    property Started: Boolean read FStarted;
    /// The start failure ('' = none / not finished). Hosts report it: the Windows
    /// Service stops itself, the daemon exits non-zero (so systemd restarts it).
    property StartError: string read FStartError;
    /// Block until the start succeeded or failed (True), or the timeout passed.
    function WaitStartDone(ATimeoutMs: Cardinal): Boolean;
  end;

implementation

const
  // TEvent.Create / TThread.Create arguments
  cManualReset = True;            // FStop / FStartDone stay set once signalled
  cInitiallyNonSignaled = False;
  cCreateSuspended = False;       // the worker starts right away

constructor TAppRunner.Create(const AConfig: TAppConfig; const ALog: TLogProc;
  const AConfigPath: string);
begin
  FConfig := AConfig;
  FLog := ALog;
  FStop := TEvent.Create(nil, cManualReset, cInitiallyNonSignaled, '');
  FStartDone := TEvent.Create(nil, cManualReset, cInitiallyNonSignaled, '');
  FContext := TAppContext.Create(FConfig, FLog, AConfigPath); // exists immediately; Start runs on the thread
  inherited Create(cCreateSuspended); // must be last: fields ready before Execute runs
end;

destructor TAppRunner.Destroy;
begin
  SignalStop;
  inherited;        // TThread.Destroy waits for Execute to finish
  FreeAndNil(FStop);
  FreeAndNil(FStartDone);
end;

procedure TAppRunner.Execute;
begin
  try
    try
      FContext.Start;
      FStarted := True;
      FStartDone.SetEvent;
      if Assigned(FLog) then
        FLog(Format('Listening on port %d (HTTPS=%s) - ready.',
          [FConfig.HttpPort, BoolToStr(FConfig.UseHttps, True)]));
    except
      on E: Exception do
      begin
        // surface bind failures etc. instead of hanging silently on "Starting..."
        FStartError := Format('%s: %s', [E.ClassName, E.Message]);
        if Assigned(FLog) then
          FLog(Format('START FAILED: %s (is port %d already in use?)',
            [FStartError, FConfig.HttpPort]));
        FStartDone.SetEvent;
        Exit;
      end;
    end;
    FStop.WaitFor(INFINITE);
  finally
    FStarted := False;
    if Assigned(FContext) then
    begin
      FContext.Stop;
      if FContext.Abandoned then
        // a refresh still runs on another thread and uses the context: freeing it
        // would be a use-after-free once that refresh ends - leave it to the exit
        FContext := nil
      else
        FreeAndNil(FContext);
    end;
  end;
end;

function TAppRunner.WaitStartDone(ATimeoutMs: Cardinal): Boolean;
begin
  Result := FStartDone.WaitFor(ATimeoutMs) = wrSignaled;
end;

procedure TAppRunner.SignalStop;
begin
  FStop.SetEvent;
end;

procedure TAppRunner.StopAndWait;
begin
  SignalStop;
  WaitFor;
end;

end.
