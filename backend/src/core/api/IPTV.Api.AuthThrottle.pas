unit IPTV.Api.AuthThrottle;

{ Rate limiting of failed logins, per client IP. Guessing an admin password or a
  bouquet login is cut down to a few tries: after cMaxFailures failures within
  cFailureWindowSec, every request from that IP is answered 429 for cLockoutSec.
  A client that logs in correctly never notices it. Thread-safe; used by the MARS
  request hooks (admin API, Xtream/M3U/XMLTV endpoints) and by the stream relay. }

interface

uses
  // RTL
  System.SyncObjs,
  System.Generics.Collections;

type
  /// <summary>Counts failed logins per client IP and locks an IP out for a while
  /// after too many.</summary>
  TAuthThrottle = class
  private
    type
      TEntry = record
        Failures: Integer;
        WindowStart: TDateTime;
        BlockedUntil: TDateTime;
      end;
  private
    FLock: TCriticalSection;
    FEntries: TDictionary<string, TEntry>;
    FMaxFailures: Integer;
    FWindowDays: Double;
    FLockoutDays: Double;
    procedure PruneLocked(ANow: TDateTime);
  public
    /// <summary>AMaxFailures failures within AWindowSec lock the IP out for ALockoutSec.</summary>
    constructor Create(AMaxFailures, AWindowSec, ALockoutSec: Integer);
    /// <summary>Frees the counters.</summary>
    destructor Destroy; override;
    /// <summary>Is this client currently locked out? ARetryAfterSec = seconds left.</summary>
    function IsBlocked(const AClientIp: string; out ARetryAfterSec: Integer): Boolean;
    /// <summary>Note one failed login (wrong password / unknown bouquet login).</summary>
    procedure RegisterFailure(const AClientIp: string);
    /// <summary>Forget all counters (tests).</summary>
    procedure Reset;
  end;

const
  /// <summary>Failed logins allowed per window before the lockout.</summary>
  cAuthMaxFailures = 10;
  /// <summary>Length of the counting window, seconds.</summary>
  cAuthFailureWindowSec = 300;
  /// <summary>Lockout after too many failures, seconds.</summary>
  cAuthLockoutSec = 300;
  /// <summary>HTTP status of a locked-out request.</summary>
  cHttpTooManyRequests = 429;

var
  /// <summary>The process-wide throttle (created in initialization).</summary>
  GAuthThrottle: TAuthThrottle;

implementation

uses
  // RTL
  System.SysUtils,
  System.DateUtils,
  System.Math;

const
  // the table never grows without bound (many distinct IPs probing)
  cMaxEntries = 10000;

constructor TAuthThrottle.Create(AMaxFailures, AWindowSec, ALockoutSec: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TEntry>.Create;
  FMaxFailures := AMaxFailures;
  FWindowDays := AWindowSec / SecsPerDay;
  FLockoutDays := ALockoutSec / SecsPerDay;
end;

destructor TAuthThrottle.Destroy;
begin
  FreeAndNil(FEntries);
  FreeAndNil(FLock);
  inherited;
end;

procedure TAuthThrottle.PruneLocked(ANow: TDateTime);
var
  lPair: TPair<string, TEntry>;
  lStale: TList<string>;
  lKey: string;
begin
  if FEntries.Count < cMaxEntries then
    Exit;
  lStale := TList<string>.Create;
  try
    for lPair in FEntries do
      if (lPair.Value.BlockedUntil < ANow) and (lPair.Value.WindowStart + FWindowDays < ANow) then
        lStale.Add(lPair.Key);
    for lKey in lStale do
      FEntries.Remove(lKey);
    // still full (a flood of fresh IPs): start over rather than grow
    if FEntries.Count >= cMaxEntries then
      FEntries.Clear;
  finally
    FreeAndNil(lStale);
  end;
end;

function TAuthThrottle.IsBlocked(const AClientIp: string; out ARetryAfterSec: Integer): Boolean;
var
  lEntry: TEntry;
  lNow: TDateTime;
begin
  ARetryAfterSec := 0;
  lNow := Now;
  FLock.Acquire;
  try
    Result := FEntries.TryGetValue(AClientIp, lEntry) and (lEntry.BlockedUntil > lNow);
    if Result then
      ARetryAfterSec := Max(1, SecondsBetween(lEntry.BlockedUntil, lNow));
  finally
    FLock.Release;
  end;
end;

procedure TAuthThrottle.RegisterFailure(const AClientIp: string);
var
  lEntry: TEntry;
  lNow: TDateTime;
begin
  lNow := Now;
  FLock.Acquire;
  try
    PruneLocked(lNow);
    if not FEntries.TryGetValue(AClientIp, lEntry) or (lEntry.WindowStart + FWindowDays < lNow) then
    begin
      lEntry.Failures := 0;
      lEntry.WindowStart := lNow;
      lEntry.BlockedUntil := 0;
    end;
    Inc(lEntry.Failures);
    if lEntry.Failures >= FMaxFailures then
    begin
      lEntry.BlockedUntil := lNow + FLockoutDays;
      lEntry.Failures := 0; // a new window starts after the lockout
      lEntry.WindowStart := lEntry.BlockedUntil;
    end;
    FEntries.AddOrSetValue(AClientIp, lEntry);
  finally
    FLock.Release;
  end;
end;

procedure TAuthThrottle.Reset;
begin
  FLock.Acquire;
  try
    FEntries.Clear;
  finally
    FLock.Release;
  end;
end;

initialization
  GAuthThrottle := TAuthThrottle.Create(cAuthMaxFailures, cAuthFailureWindowSec, cAuthLockoutSec);

finalization
  FreeAndNil(GAuthThrottle);

end.
