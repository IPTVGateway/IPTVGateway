unit IPTV.Scheduler;

{ Fires a daily refresh at a configured local time (e.g. 04:00). Runs as a
  background thread so it behaves identically in the VCL dev host and the
  service/daemon — no UI timer, no host-specific code.

  The thread sleeps in short slices and checks the wall clock, so changing the
  system time or resuming from sleep can at most delay the run by one slice. }

interface

uses
  // RTL
  System.Classes,
  System.SysUtils,
  System.SyncObjs;

type
  /// Background thread that calls OnFire once a day at Hour:Minute (local time).
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
    /// Starts the thread right away; AOnFire runs on the scheduler thread.
    constructor Create(AHour, AMinute: Word; const AOnFire: TThreadProcedure);
    destructor Destroy; override;
    property Hour: Word read FHour write FHour;
    property Minute: Word read FMinute write FMinute;
  end;

implementation

uses
  // RTL
  System.DateUtils;

const
  // TEvent.Create / TThread.Create arguments
  cAutoReset = False;             // ManualReset argument: FWake is auto-reset
  cInitiallyNonSignaled = False;
  cCreateSuspended = False;       // the thread starts right away
  // the thread re-checks the clock at least this often
  cWakeSliceMs = 30000;

constructor TDailyScheduler.Create(AHour, AMinute: Word; const AOnFire: TThreadProcedure);
begin
  FWake := TEvent.Create(nil, cAutoReset, cInitiallyNonSignaled, '');
  inherited Create(cCreateSuspended);
  FreeOnTerminate := False;
  FHour := AHour;
  FMinute := AMinute;
  FOnFire := AOnFire;
  FLastRunDate := 0;
end;

destructor TDailyScheduler.Destroy;
begin
  inherited; // ensure the thread has finished before freeing the event it waits on
  FreeAndNil(FWake);
end;

// called by Terminate (possibly from another thread) — wake the sleep immediately
procedure TDailyScheduler.TerminatedSet;
begin
  FWake.SetEvent;
  inherited;
end;

function TDailyScheduler.DueNow: Boolean;
const
  // two hours after the configured time: one for the run itself plus one for the
  // DST jump (see below)
  cFireWindowHours = 2;
  cFireWindow = cFireWindowHours / HoursPerDay;
var
  lNow, lTarget: TDateTime;
begin
  lNow := Now;
  lTarget := DateOf(lNow) + EncodeTime(FHour, FMinute, 0, 0);
  // fire only DURING the window after the configured time — crucially NOT on every
  // startup that happens to be past the daily time, which would run a heavy full
  // refresh (holding the store lock, hanging the UI) on every container restart.
  // A window, not "hour = FHour", and two hours wide: on the spring DST day the
  // clock jumps 01:59:59 -> 03:00:00, so a 02:00 (or 02:30) target is first seen at
  // 03:00 - a one-hour window would end exactly there and skip the day's run.
  // FLastRunDate keeps it to one run per day.
  Result := (DateOf(lNow) <> FLastRunDate) and (lNow >= lTarget) and
    (lNow < lTarget + cFireWindow);
end;

procedure TDailyScheduler.Execute;
begin
  while not Terminated do
  begin
    if DueNow then
    begin
      FLastRunDate := DateOf(Now);
      // an escaping exception would end this thread for good (no more daily
      // refreshes until a restart) - the callback logs its own errors
      if Assigned(FOnFire) then
        try
          FOnFire();
        except
          // swallowed on purpose: keep scheduling
        end;
    end;
    // wait up to one slice; Terminate signals FWake so shutdown returns immediately
    FWake.WaitFor(cWakeSliceMs);
  end;
end;

end.
