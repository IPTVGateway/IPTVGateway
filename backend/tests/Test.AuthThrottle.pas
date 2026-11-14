unit Test.AuthThrottle;

{ Tests for IPTV.Api.AuthThrottle: lockout after too many failed logins, a good
  login clearing the counter, the lockout key (trusted proxies + X-Forwarded-For)
  and the separation of the admin and box surfaces. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for the failed-login throttle.</summary>
  [TestFixture]
  TAuthThrottleTests = class
  public
    /// <summary>The key is locked out once the failure limit is reached.</summary>
    [Test] procedure LocksOutAfterMaxFailures;
    /// <summary>A successful login forgets the earlier failures.</summary>
    [Test] procedure SuccessResetsTheCounter;
    /// <summary>A success does not lift a running lockout.</summary>
    [Test] procedure SuccessKeepsARunningLockout;
    /// <summary>Without trusted proxies X-Forwarded-For is ignored.</summary>
    [Test] procedure ClientKeyIgnoresForwardedForFromUntrusted;
    /// <summary>From a trusted proxy the first X-Forwarded-For address is the client.</summary>
    [Test] procedure ClientKeyUsesForwardedForFromTrustedProxy;
    /// <summary>The admin and box surfaces are counted separately.</summary>
    [Test] procedure SurfacesAreSeparate;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Api.AuthThrottle;

const
  cTestMaxFailures = 3;
  cTestWindowSec = 60;
  cTestLockoutSec = 60;
  cClientIp = '10.0.0.5';
  cOtherIp = '10.0.0.6';
  cProxyIp = '192.168.1.2';
  cForwarded = '203.0.113.7, 192.168.1.2';
  cForwardedClient = '203.0.113.7';

function NewThrottle: TAuthThrottle;
begin
  Result := TAuthThrottle.Create(cTestMaxFailures, cTestWindowSec, cTestLockoutSec);
end;

procedure FailTimes(AThrottle: TAuthThrottle; const AKey: string; ACount: Integer);
var
  i: Integer;
begin
  for i := 1 to ACount do
    AThrottle.RegisterFailure(AKey);
end;

procedure TAuthThrottleTests.LocksOutAfterMaxFailures;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
begin
  lThrottle := NewThrottle;
  try
    FailTimes(lThrottle, cClientIp, cTestMaxFailures - 1);
    Assert.IsFalse(lThrottle.IsBlocked(cClientIp, lRetryAfter), 'below the limit');
    lThrottle.RegisterFailure(cClientIp);
    Assert.IsTrue(lThrottle.IsBlocked(cClientIp, lRetryAfter), 'limit reached');
    Assert.IsTrue((lRetryAfter > 0) and (lRetryAfter <= cTestLockoutSec), 'Retry-After in range');
    Assert.IsFalse(lThrottle.IsBlocked(cOtherIp, lRetryAfter), 'another client is not affected');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TAuthThrottleTests.SuccessResetsTheCounter;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
begin
  lThrottle := NewThrottle;
  try
    FailTimes(lThrottle, cClientIp, cTestMaxFailures - 1);
    lThrottle.RegisterSuccess(cClientIp);
    // without the reset this would reach the limit
    FailTimes(lThrottle, cClientIp, cTestMaxFailures - 1);
    Assert.IsFalse(lThrottle.IsBlocked(cClientIp, lRetryAfter), 'one good login clears the earlier typos');
    lThrottle.RegisterSuccess(cOtherIp); // unknown key: no-op
    Assert.IsFalse(lThrottle.IsBlocked(cOtherIp, lRetryAfter));
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TAuthThrottleTests.SuccessKeepsARunningLockout;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
begin
  lThrottle := NewThrottle;
  try
    FailTimes(lThrottle, cClientIp, cTestMaxFailures);
    lThrottle.RegisterSuccess(cClientIp);
    Assert.IsTrue(lThrottle.IsBlocked(cClientIp, lRetryAfter), 'the lockout runs its course');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TAuthThrottleTests.ClientKeyIgnoresForwardedForFromUntrusted;
var
  lThrottle: TAuthThrottle;
begin
  lThrottle := NewThrottle;
  try
    Assert.AreEqual(cSurfaceBox + ':' + cProxyIp, lThrottle.ClientKey(cSurfaceBox, cProxyIp, cForwarded),
      'no trusted proxies: the header is attacker-controlled and ignored');
    lThrottle.TrustedProxies := [cProxyIp];
    Assert.AreEqual(cSurfaceBox + ':' + cClientIp, lThrottle.ClientKey(cSurfaceBox, cClientIp, cForwarded),
      'a client that is not a trusted proxy cannot pick its own key');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TAuthThrottleTests.ClientKeyUsesForwardedForFromTrustedProxy;
var
  lThrottle: TAuthThrottle;
begin
  lThrottle := NewThrottle;
  try
    lThrottle.TrustedProxies := [' ' + cProxyIp + ' '];
    Assert.AreEqual(cSurfaceAdmin + ':' + cForwardedClient,
      lThrottle.ClientKey(cSurfaceAdmin, cProxyIp, cForwarded), 'first X-Forwarded-For address');
    Assert.AreEqual(cSurfaceAdmin + ':' + cForwardedClient,
      lThrottle.ClientKey(cSurfaceAdmin, cProxyIp, cForwardedClient), 'a single address');
    Assert.AreEqual(cSurfaceAdmin + ':' + cProxyIp, lThrottle.ClientKey(cSurfaceAdmin, cProxyIp, ''),
      'no header: the proxy itself');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TAuthThrottleTests.SurfacesAreSeparate;
var
  lThrottle: TAuthThrottle;
  lAdminKey, lBoxKey: string;
  lRetryAfter: Integer;
begin
  lThrottle := NewThrottle;
  try
    lAdminKey := lThrottle.ClientKey(cSurfaceAdmin, cClientIp, '');
    lBoxKey := lThrottle.ClientKey(cSurfaceBox, cClientIp, '');
    Assert.IsFalse(SameStr(lAdminKey, lBoxKey), 'one key per surface');
    FailTimes(lThrottle, lBoxKey, cTestMaxFailures);
    Assert.IsTrue(lThrottle.IsBlocked(lBoxKey, lRetryAfter), 'box surface locked out');
    Assert.IsFalse(lThrottle.IsBlocked(lAdminKey, lRetryAfter), 'a box guessing never locks the web app out');
  finally
    FreeAndNil(lThrottle);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TAuthThrottleTests);

end.
