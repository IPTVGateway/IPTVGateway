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
    FMaxEntries: Integer;
    /// Makes room for one more key; False when the table is full of blocked keys.
    function MakeRoomLocked(ANowMs: UInt64): Boolean;
    function GetTrustedProxies: TArray<string>;
    procedure SetTrustedProxies(const AValue: TArray<string>);
    function IsTrustedProxy(const AIp: string): Boolean;
  public
    /// <summary>AMaxFailures failures within AWindowSec lock the key out for ALockoutSec.
    /// At most AMaxEntries keys are tracked (0 = the default cap).</summary>
    constructor Create(AMaxFailures, AWindowSec, ALockoutSec: Integer; AMaxEntries: Integer = 0);
    /// <summary>Frees the counters.</summary>
    destructor Destroy; override;
    /// <summary>Is this key currently locked out? ARetryAfterSec = seconds left.</summary>
    function IsBlocked(const AKey: string; out ARetryAfterSec: Integer): Boolean;
    /// <summary>Note one failed login (wrong password / unknown bouquet login).</summary>
    procedure RegisterFailure(const AKey: string);
    /// <summary>Note a successful login: forgets the failures of that key (an
    /// active lockout stays until it ends).</summary>
    procedure RegisterSuccess(const AKey: string);
    /// <summary>The client address of a request: the right-most X-Forwarded-For
    /// address that is not itself a trusted proxy when ARemoteIp is one of the
    /// TrustedProxies, else ARemoteIp (trimmed).</summary>
    function ClientAddress(const ARemoteIp, AForwardedFor: string): string;
    /// <summary>Is the request from the local network? The client address
    /// (ClientAddress) must be private/local - and when the peer is NOT a trusted proxy
    /// but forwards an X-Forwarded-For (an untrusted reverse proxy on the LAN), the
    /// right-most forwarded hop must be private/local too.</summary>
    function IsLocalClient(const ARemoteIp, AForwardedFor: string): Boolean;
    /// <summary>The lockout key of a request: ASurface + ':' + the client address
    /// (ClientAddress), IPv6 reduced to its /64 (IPTV.Api.Security.ClientAddressKey).</summary>
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

/// <summary>All X-Forwarded-For header lines of a request as one value, in order
/// (a client or proxy may send the header more than once; reading only the first line
/// would let the walk start from an attacker-chosen hop). Blank lines are dropped.</summary>
function JoinForwardedFor(const ALines: TArray<string>): string;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Math,
  System.Generics.Defaults,
  // own units
  IPTV.Api.Security;

const
  // the table never grows without bound (many distinct IPs probing)
  cDefaultMaxEntries = 10000;
  // on overflow this share of the cap is freed at once (amortises the scan)
  cEvictDivisor = 10;
  cMsPerSec = 1000;
  // ClientKey: '<surface>:<client>'; X-Forwarded-For is 'client, proxy1, proxy2'
  cKeySeparator = ':';
  cForwardedSeparator = ',';
  cForwardedJoin = ', ';

function JoinForwardedFor(const ALines: TArray<string>): string;
var
  lLine: string;
begin
  Result := '';
  for lLine in ALines do
    if lLine.Trim <> '' then
    begin
      if Result <> '' then
        Result := Result + cForwardedJoin;
      Result := Result + lLine.Trim;
    end;
end;

constructor TAuthThrottle.Create(AMaxFailures, AWindowSec, ALockoutSec: Integer; AMaxEntries: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FEntries := TDictionary<string, TEntry>.Create;
  FTrustedProxies := [];
  FMaxFailures := AMaxFailures;
  FWindowMs := UInt64(Max(0, AWindowSec)) * cMsPerSec;
  FLockoutMs := UInt64(Max(0, ALockoutSec)) * cMsPerSec;
  if AMaxEntries > 0 then
    FMaxEntries := AMaxEntries
  else
    FMaxEntries := cDefaultMaxEntries;
end;

destructor TAuthThrottle.Destroy;
begin
  FreeAndNil(FEntries);
  FreeAndNil(FLock);
  inherited;
end;

function TAuthThrottle.MakeRoomLocked(ANowMs: UInt64): Boolean;
var
  lPair: TPair<string, TEntry>;
  lStale: TList<string>;
  lFree: TList<TPair<string, TEntry>>;
  lKey: string;
  lTarget: Integer;
  i: Integer;
begin
  if FEntries.Count < FMaxEntries then
    Exit(True);
  lStale := TList<string>.Create;
  lFree := TList<TPair<string, TEntry>>.Create;
  try
    // 1) entries whose window and lockout are both over carry no information
    for lPair in FEntries do
      if lPair.Value.BlockedUntilMs <= ANowMs then
      begin
        if lPair.Value.WindowStartMs + FWindowMs < ANowMs then
          lStale.Add(lPair.Key)
        else
          lFree.Add(lPair);
      end;
    for lKey in lStale do
      FEntries.Remove(lKey);
    // 2) still full: evict counting (not blocked) entries, oldest window first.
    // Blocked keys are never dropped - a flood of fresh IPs must not lift lockouts.
    if FEntries.Count >= FMaxEntries then
    begin
      lFree.Sort(TComparer<TPair<string, TEntry>>.Construct(
        function (const ALeft, ARight: TPair<string, TEntry>): Integer
        begin
          if ALeft.Value.WindowStartMs < ARight.Value.WindowStartMs then
            Result := -1
          else if ALeft.Value.WindowStartMs > ARight.Value.WindowStartMs then
            Result := 1
          else
            Result := 0;
        end));
      lTarget := FMaxEntries - Max(1, FMaxEntries div cEvictDivisor);
      i := 0;
      while (FEntries.Count > lTarget) and (i < lFree.Count) do
      begin
        FEntries.Remove(lFree[i].Key);
        Inc(i);
      end;
    end;
    // 3) full of blocked keys: the caller doesn't track the new key
    Result := FEntries.Count < FMaxEntries;
  finally
    FreeAndNil(lFree);
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
    if not FEntries.ContainsKey(AKey) and not MakeRoomLocked(lNowMs) then
      Exit; // the table is full of locked-out keys: don't track (never clear them)
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

function TAuthThrottle.ClientAddress(const ARemoteIp, AForwardedFor: string): string;
var
  lHops: TArray<string>;
  lHop: string;
  i: Integer;
begin
  Result := ARemoteIp.Trim;
  // only a known reverse proxy may name the real client; from anyone else the
  // header is attacker-controlled and would let a guesser pick a fresh key per try.
  // Walk X-Forwarded-For right to left: each proxy APPENDS the address it saw, so the
  // left part can be forged by the client; the right-most hop that is not one of our
  // own trusted proxies is the address our proxy chain actually received it from.
  if (AForwardedFor.Trim <> '') and IsTrustedProxy(Result) then
  begin
    lHops := AForwardedFor.Split([cForwardedSeparator]);
    for i := High(lHops) downto Low(lHops) do
    begin
      lHop := lHops[i].Trim;
      if lHop = '' then
        Continue;
      Result := lHop;
      if not IsTrustedProxy(lHop) then
        Break;
    end;
  end;
end;

function TAuthThrottle.IsLocalClient(const ARemoteIp, AForwardedFor: string): Boolean;
var
  lHops: TArray<string>;
  i: Integer;
begin
  Result := IsPrivateAddress(ClientAddress(ARemoteIp, AForwardedFor));
  if not Result or IsTrustedProxy(ARemoteIp.Trim) or (AForwardedFor.Trim = '') then
    Exit;
  // a LAN peer that forwards for someone (a reverse proxy not listed in trustedProxies):
  // the hop it received the request from must be local too
  lHops := AForwardedFor.Split([cForwardedSeparator]);
  for i := High(lHops) downto Low(lHops) do
    if lHops[i].Trim <> '' then
      Exit(IsPrivateAddress(lHops[i].Trim));
end;

function TAuthThrottle.ClientKey(const ASurface, ARemoteIp, AForwardedFor: string): string;
begin
  Result := ASurface + cKeySeparator + ClientAddressKey(ClientAddress(ARemoteIp, AForwardedFor));
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
