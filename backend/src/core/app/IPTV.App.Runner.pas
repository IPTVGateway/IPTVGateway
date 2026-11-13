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
  System.SysUtils, System.Classes, System.SyncObjs,
  IPTV.App.Config, IPTV.App.Context, IPTV.Ingest.Service;

type
  TAppRunner = class(TThread)
  private
    FConfig: TAppConfig;
    FLog: TLogProc;
    FContext: TAppContext;
    FStop: TEvent;
    FStarted: Boolean;
  protected
    procedure Execute; override;
  public
    /// AConfigPath is forwarded to TAppContext: where settings are loaded/saved
    /// (empty => config.json next to the exe). The Windows Service passes a
    /// writable ProgramData path.
    constructor Create(const AConfig: TAppConfig; const ALog: TLogProc = nil;
      const AConfigPath: string = '');
    destructor Destroy; override;
    procedure SignalStop;   // ask the worker to wind down (non-blocking)
    procedure StopAndWait;  // SignalStop + block until fully stopped
    property Context: TAppContext read FContext; // valid once created; check Started before use
    property Started: Boolean read FStarted;
  end;

implementation

constructor TAppRunner.Create(const AConfig: TAppConfig; const ALog: TLogProc;
  const AConfigPath: string);
begin
  FConfig := AConfig;
  FLog := ALog;
  FStop := TEvent.Create(nil, True, False, '');
  FContext := TAppContext.Create(FConfig, FLog, AConfigPath); // exists immediately; Start runs on the thread
  inherited Create(False); // must be last: fields ready before Execute runs
end;

destructor TAppRunner.Destroy;
begin
  SignalStop;
  inherited;        // TThread.Destroy waits for Execute to finish
  FStop.Free;
end;

procedure TAppRunner.Execute;
begin
  try
    try
      FContext.Start;
      FStarted := True;
      if Assigned(FLog) then
        FLog(Format('Listening on port %d (HTTPS=%s) - ready.',
          [FConfig.HttpPort, BoolToStr(FConfig.UseHttps, True)]));
    except
      on E: Exception do
      begin
        // surface bind failures etc. instead of hanging silently on "Starting..."
        if Assigned(FLog) then
          FLog(Format('START FAILED: %s: %s (is port %d already in use?)',
            [E.ClassName, E.Message, FConfig.HttpPort]));
        Exit;
      end;
    end;
    FStop.WaitFor(INFINITE);
  finally
    FStarted := False;
    if Assigned(FContext) then
      FContext.Stop;
    FreeAndNil(FContext);
  end;
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
