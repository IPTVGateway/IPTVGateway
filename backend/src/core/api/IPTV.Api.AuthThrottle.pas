unit IPTV.Api.AuthThrottle;

{ Rate limiting of failed logins, per client and surface. Guessing an admin password
  or a bouquet login is cut down to a few tries: after cMaxFailures failures within
  cFailureWindowSec, every request with that key is answered 429 for cLockoutSec.
  A client that logs in correctly never notices it (a success clears its counter).
  Times come from a monotonic clock (TThread.GetTickCount64), so a DST switch or a
  clock change can't stretch or shorten a lockout. Thread-safe; used by the MARS
  request hooks (admin API, Xtream/M3U/XMLTV endpoints) and by the stream relay. }

interface

uses
  // RTL
  System.SyncObjs,
  System.Generics.Collections;

type
  /// <summary>Counts failed logins per key (surface + client IP) and locks a key
  /// out for a while after too many.</summary>
  TAuthThrottle = class
  private
    type
      TEntry = record
        Failures: Integer;
        WindowStartMs: UInt64;
        BlockedUntilMs: UInt64; // 0 = not blocked
      end;
  private
    FLock: TCriticalSection;
    FEntries: TDictionary<string, TEntry>;
    FTrustedProxies: TArray<string>;
    FMaxFailures: Integer;
    FWindowMs: UInt64;
    FLockoutMs: UInt64;
    procedure PruneLocked(ANowMs: UInt64);
    function GetTrustedProxies: TArray<string>;
    procedure SetTrustedProxies(const AValue: TArray<string>);
    function IsTrustedProxy(const AIp: string): Boolean;
  public
    /// <summary>AMaxFailures failures within AWindowSec lock the key out for ALockoutSec.</summary>
    constructor Create(AMaxFailures, AWindowSec, ALockoutSec: Integer);
    /// <summary>Frees the counters.</summary>
    destructor Destroy; override;
    /// <summary>Is this key currently locked out? ARetryAfterSec = seconds left.</summary>
    function IsBlocked(const AKey: string; out ARetryAfterSec: Integer): Boolean;
    /// <summary>Note one failed login (wrong password / unknown bouquet login).</summary>
    procedure RegisterFailure(const AKey: string);
    /// <summary>Note a successful login: forgets the failures of that key (an
    /// active lockout stays until it ends).</summary>
    procedure RegisterSuccess(const AKey: string);
    /// <summary>The lockout key of a request: ASurface + ':' + client, where client
    /// is the first X-Forwarded-For address when ARemoteIp is one of the
    /// TrustedProxies, else ARemoteIp.</summary>
    function ClientKey(const ASurface, ARemoteIp, AForwardedFor: string): string;
    /// <summary>Forget all counters (tests).</summary>
    procedure Reset;
    /// <summary>Reverse proxies whose X-Forwarded-For is believed (exact IPs; set
    /// by the server from config). Empty = the header is ignored.</summary>
    property TrustedProxies: TArray<string> read GetTrustedProxies write SetTrustedProxies;
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
  /// <summary>Lockout surface of the admin API (/api).</summary>
  cSurfaceAdmin = 'admin';
  /// <summary>Lockout surface of the box endpoints (Xtream/M3U/XMLTV/relay).</summary>
  cSurfaceBox = 'box';
  /// <summary>Header a reverse proxy puts the original client address in.</summary>
  cHeaderForwardedFor = 'X-Forwarded-For';
  /// <summary>Header of the server's own startup warm-up requests (their failures
  /// don't count).</summary>
  cWarmupHeader = 'X-IPTV-Warmup';

var
  /// <summary>The process-wide throttle (created in initialization).</summary>
  GAuthThrottle: TAuthThrottle;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Math;

const
  // the table never grows without bound (many distinct IPs probing)
  cMaxEntries = 10000;
  cMsPerSec = 1000;
  // ClientKey: '<surface>:<client>'; X-Forwarded-For is 'client, proxy1, proxy2'
  cKeySeparator = ':';
  cForwardedSeparator = ',';

constructor TAuthThrottle.Create(AMaxFailures, AWindowSec, ALockoutSec: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TEntry>.Create;
  FTrustedProxies := [];
  FMaxFailures := AMaxFailures;
  FWindowMs := UInt64(Max(0, AWindowSec)) * cMsPerSec;
  FLockoutMs := UInt64(Max(0, ALockoutSec)) * cMsPerSec;
end;

destructor TAuthThrottle.Destroy;
begin
  FreeAndNil(FEntries);
  FreeAndNil(FLock);
  inherited;
end;

procedure TAuthThrottle.PruneLocked(ANowMs: UInt64);
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
      if (lPair.Value.BlockedUntilMs <= ANowMs) and (lPair.Value.WindowStartMs + FWindowMs < ANowMs) then
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

function TAuthThrottle.IsBlocked(const AKey: string; out ARetryAfterSec: Integer): Boolean;
var
  lEntry: TEntry;
  lNowMs: UInt64;
begin
  ARetryAfterSec := 0;
  lNowMs := TThread.GetTickCount64;
  FLock.Acquire;
  try
    Result := FEntries.TryGetValue(AKey, lEntry) and (lEntry.BlockedUntilMs > lNowMs);
    if Result then
      ARetryAfterSec := Max(1, Integer((lEntry.BlockedUntilMs - lNowMs + cMsPerSec - 1) div cMsPerSec));
  finally
    FLock.Release;
  end;
end;

procedure TAuthThrottle.RegisterFailure(const AKey: string);
var
  lEntry: TEntry;
  lNowMs: UInt64;
begin
  lNowMs := TThread.GetTickCount64;
  FLock.Acquire;
  try
    PruneLocked(lNowMs);
    if not FEntries.TryGetValue(AKey, lEntry) or (lEntry.WindowStartMs + FWindowMs < lNowMs) then
    begin
      lEntry.Failures := 0;
      lEntry.WindowStartMs := lNowMs;
      lEntry.BlockedUntilMs := 0;
    end;
    Inc(lEntry.Failures);
    if lEntry.Failures >= FMaxFailures then
    begin
      lEntry.BlockedUntilMs := lNowMs + FLockoutMs;
      lEntry.Failures := 0; // a new window starts after the lockout
      lEntry.WindowStartMs := lEntry.BlockedUntilMs;
    end;
    FEntries.AddOrSetValue(AKey, lEntry);
  finally
    FLock.Release;
  end;
end;

procedure TAuthThrottle.RegisterSuccess(const AKey: string);
var
  lEntry: TEntry;
begin
  FLock.Acquire;
  try
    if not FEntries.TryGetValue(AKey, lEntry) then
      Exit;
    // a running lockout is not lifted (a request that got through belongs to the
    // same guesser); otherwise the counter is gone
    if lEntry.BlockedUntilMs > TThread.GetTickCount64 then
      Exit;
    FEntries.Remove(AKey);
  finally
    FLock.Release;
  end;
end;

function TAuthThrottle.GetTrustedProxies: TArray<string>;
begin
  FLock.Acquire;
  try
    Result := Copy(FTrustedProxies);
  finally
    FLock.Release;
  end;
end;

procedure TAuthThrottle.SetTrustedProxies(const AValue: TArray<string>);
var
  lList: TArray<string>;
  lItem: string;
begin
  lList := [];
  for lItem in AValue do
    if lItem.Trim <> '' then
      lList := lList + [lItem.Trim];
  FLock.Acquire;
  try
    FTrustedProxies := lList;
  finally
    FLock.Release;
  end;
end;

function TAuthThrottle.IsTrustedProxy(const AIp: string): Boolean;
var
  lItem: string;
begin
  Result := False;
  FLock.Acquire;
  try
    for lItem in FTrustedProxies do
      if SameText(lItem, AIp) then
        Exit(True);
  finally
    FLock.Release;
  end;
end;

function TAuthThrottle.ClientKey(const ASurface, ARemoteIp, AForwardedFor: string): string;
var
  lClient: string;
  lSepPos: Integer;
begin
  lClient := ARemoteIp.Trim;
  // only a known reverse proxy may name the real client; from anyone else the
  // header is attacker-controlled and would let a guesser pick a fresh key per try
  if (AForwardedFor.Trim <> '') and IsTrustedProxy(lClient) then
  begin
    lSepPos := Pos(cForwardedSeparator, AForwardedFor);
    if lSepPos > 0 then
      lClient := Copy(AForwardedFor, 1, lSepPos - 1).Trim
    else
      lClient := AForwardedFor.Trim;
    if lClient = '' then
      lClient := ARemoteIp.Trim;
  end;
  Result := ASurface + cKeySeparator + lClient;
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
