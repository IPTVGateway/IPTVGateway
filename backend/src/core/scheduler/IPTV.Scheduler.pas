unit IPTV.Scheduler;

{ Fires a daily refresh at a configured local time (e.g. 04:00). Runs as a
  background thread so it behaves identically in the VCL dev host and the
  service/daemon — no UI timer, no host-specific code.

  The thread sleeps in short slices and checks the wall clock, so changing the
  system time or resuming from sleep can at most delay the run by one slice. }

interface

uses
  System.Classes, System.SysUtils, System.SyncObjs;

type
  TDailyScheduler = class(TThread)
  private
    FHour: Word;
    FMinute: Word;
    FOnFire: TThreadProcedure;
    FLastRunDate: TDate;
    FWake: TEvent; // signalled by Terminate so shutdown doesn't wait out the slice
    function DueNow: Boolean;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(AHour, AMinute: Word; const AOnFire: TThreadProcedure);
    destructor Destroy; override;
    property Hour: Word read FHour write FHour;
    property Minute: Word read FMinute write FMinute;
  end;

implementation

uses
  System.DateUtils;

constructor TDailyScheduler.Create(AHour, AMinute: Word; const AOnFire: TThreadProcedure);
begin
  FWake := TEvent.Create(nil, False, False, ''); // auto-reset
  inherited Create(False);
  FreeOnTerminate := False;
  FHour := AHour;
  FMinute := AMinute;
  FOnFire := AOnFire;
  FLastRunDate := 0;
end;

destructor TDailyScheduler.Destroy;
begin
  inherited; // ensure the thread has finished before freeing the event it waits on
  FWake.Free;
end;

// called by Terminate (possibly from another thread) — wake the sleep immediately
procedure TDailyScheduler.TerminatedSet;
begin
  FWake.SetEvent;
  inherited;
end;

function TDailyScheduler.DueNow: Boolean;
var
  N: TDateTime;
begin
  N := Now;
  // fire only DURING the configured minute window — crucially NOT on every startup
  // that happens to be past the daily time, which would run a heavy full refresh
  // (holding the store lock, hanging the UI) on every container restart.
  Result := (DateOf(N) <> FLastRunDate) and
            (HourOf(N) = FHour) and (MinuteOf(N) >= FMinute);
end;

procedure TDailyScheduler.Execute;
begin
  while not Terminated do
  begin
    if DueNow then
    begin
      FLastRunDate := DateOf(Now);
      if Assigned(FOnFire) then
        FOnFire();
    end;
    // wait up to 30s; Terminate signals FWake so shutdown returns immediately
    FWake.WaitFor(30000);
  end;
end;

end.
