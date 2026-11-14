unit Test.Security;

{ Tests for the pure security helpers (IPTV.Api.Security) and the hardened parts of
  the failed-login throttle (IPTV.Api.AuthThrottle): address classification, the
  Plex/HDHomeRun LAN-only default, the admin Host rule (DNS rebinding), the relay's
  redirect guard, the body cap, download tokens, X-Forwarded-For right-to-left and
  the overflow eviction that never drops a lockout. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for the security helpers.</summary>
  [TestFixture]
  TSecurityTests = class
  public
    /// <summary>Private/loopback/link-local IPv4 + IPv6 (incl. ::ffff:) vs public.</summary>
    [Test] procedure PrivateAddresses;
    /// <summary>Empty allow-list = LAN only; a list keeps working as before.</summary>
    [Test] procedure MediaClientsDefaultToLan;
    /// <summary>Host header: port, brackets, case and a trailing dot are removed.</summary>
    [Test] procedure HostHeaderNames;
    /// <summary>The admin Host rule without a password.</summary>
    [Test] procedure AdminHostRule;
    /// <summary>No relay redirect to an internal address from a public upstream.</summary>
    [Test] procedure RedirectGuard;
    /// <summary>Content-Length above the cap.</summary>
    [Test] procedure BodyCap;
    /// <summary>Download tokens: bound to their path, reusable until they expire.</summary>
    [Test] procedure DownloadTokens;
    /// <summary>Only the bouquet export downloads get a download token.</summary>
    [Test] procedure DownloadTokenPaths;
    /// <summary>CSPRNG output: length, hex, uniqueness.</summary>
    [Test] procedure SecureRandom;
    /// <summary>IPv4 octets with a leading zero (octal to WinSock) are no address.</summary>
    [Test] procedure Ipv4LeadingZeros;
    /// <summary>100.64.0.0/10 (CGNAT / Tailscale) counts as private.</summary>
    [Test] procedure CgnatIsPrivate;
    /// <summary>Router / VPN host names (.box, .home, .ts.net, ...) pass the Host rule.</summary>
    [Test] procedure AdminHostRuleHomeSuffixes;
    /// <summary>An import keeps the current Host in allowedHosts when it needs it.</summary>
    [Test] procedure HostsKeptOnImport;
    /// <summary>JSON nesting depth scan (strings and escapes ignored).</summary>
    [Test] procedure JsonDepth;
    /// <summary>1 MB body cap, 64 MB for the settings import only.</summary>
    [Test] procedure BodyCapPerRoute;
    /// <summary>The warm-up header only counts with the exact current token.</summary>
    [Test] procedure WarmupToken;
    /// <summary>'' and '-' are no box login.</summary>
    [Test] procedure RealLoginNames;
    /// <summary>IPv6 clients are keyed by their /64.</summary>
    [Test] procedure Ipv6KeyedBy64;
    /// <summary>All X-Forwarded-For lines are joined in order before the walk.</summary>
    [Test] procedure ForwardedForLinesJoined;
    /// <summary>The local-client rule (trusted proxy / untrusted LAN proxy).</summary>
    [Test] procedure LocalClientRule;
    /// <summary>Masked extra-EPG URL secrets are restored only onto the same URL.</summary>
    [Test] procedure MaskedUrlListRestore;
    /// <summary>X-Forwarded-For is read right to left, skipping trusted proxies.</summary>
    [Test] procedure ForwardedForRightMost;
    /// <summary>A full table evicts counting entries, never a lockout.</summary>
    [Test] procedure OverflowKeepsLockouts;
    /// <summary>A table full of lockouts doesn't track a new key (and clears nothing).</summary>
    [Test] procedure OverflowFullOfLockouts;
    /// <summary>Provider passwords are write-only in the admin JSON; a missing key keeps.</summary>
    [Test] procedure SourcePasswordWriteOnly;
    /// <summary>Mirror credential passwords are write-only; a row without the key keeps.</summary>
    [Test] procedure MirrorPasswordWriteOnly;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  System.RegularExpressions,
  // own units
  IPTV.Model.Source,
  IPTV.Model.CustomList,
  IPTV.Api.Serializers,
  IPTV.Api.Security,
  IPTV.Api.AuthThrottle;

const
  cTestWindowSec = 60;
  cTestLockoutSec = 60;
  cProxyA = '192.168.1.2';
  cProxyB = '192.168.1.3';
  cRealClient = '203.0.113.7';
  cSpoofed = '1.1.1.1';
  cRebindHost = 'rebind.example';
  cRebindIp = '10.0.0.5';

procedure TSecurityTests.PrivateAddresses;
begin
  Assert.IsTrue(IsPrivateAddress('127.0.0.1'), 'loopback');
  Assert.IsTrue(IsPrivateAddress('10.1.2.3'), '10/8');
  Assert.IsTrue(IsPrivateAddress('172.16.0.1'), '172.16/12 low');
  Assert.IsTrue(IsPrivateAddress('172.31.255.255'), '172.16/12 high');
  Assert.IsFalse(IsPrivateAddress('172.32.0.1'), 'just outside 172.16/12');
  Assert.IsTrue(IsPrivateAddress('192.168.1.1'), '192.168/16');
  Assert.IsTrue(IsPrivateAddress('169.254.10.1'), 'link-local');
  Assert.IsFalse(IsPrivateAddress('8.8.8.8'), 'public');
  Assert.IsFalse(IsPrivateAddress('203.0.113.5'), 'public (doc range)');
  Assert.IsTrue(IsPrivateAddress('::1'), 'IPv6 loopback');
  Assert.IsTrue(IsPrivateAddress('[::1]'), 'bracketed');
  Assert.IsTrue(IsPrivateAddress('fe80::1%eth0'), 'IPv6 link-local with zone');
  Assert.IsTrue(IsPrivateAddress('fd12:3456::1'), 'ULA fd');
  Assert.IsTrue(IsPrivateAddress('fc00::1'), 'ULA fc');
  Assert.IsFalse(IsPrivateAddress('2001:db8::1'), 'public IPv6');
  Assert.IsTrue(IsPrivateAddress('::ffff:192.168.1.5'), 'mapped private');
  Assert.IsFalse(IsPrivateAddress('::ffff:8.8.8.8'), 'mapped public');
  Assert.IsTrue(IsPrivateAddress('::FFFF:c0a8:0105'), 'mapped private, hex form');
  Assert.IsFalse(IsPrivateAddress('256.1.1.1'), 'not an address');
  Assert.IsFalse(IsPrivateAddress('nas.lan'), 'a name is not an address');
  Assert.IsFalse(IsPrivateAddress(''), 'empty');
  Assert.IsFalse(IsPrivateAddress('1:2:3:4:5:6:7:8:9'), 'too many IPv6 groups');
end;

procedure TSecurityTests.MediaClientsDefaultToLan;
begin
  Assert.IsTrue(IsMediaClientPermitted('192.168.1.20', []), 'LAN client, no list');
  Assert.IsTrue(IsMediaClientPermitted('::ffff:10.0.0.9', []), 'mapped LAN client, no list');
  Assert.IsFalse(IsMediaClientPermitted('203.0.113.5', []), 'internet client, no list');
  Assert.IsFalse(IsMediaClientPermitted('::ffff:203.0.113.5', []), 'mapped internet client, no list');
  Assert.IsTrue(IsMediaClientPermitted('203.0.113.5', ['203.0.113.']), 'a listed prefix');
  Assert.IsFalse(IsMediaClientPermitted('192.168.1.20', ['203.0.113.']), 'a list is exact: LAN not implied');
end;

procedure TSecurityTests.HostHeaderNames;
begin
  Assert.AreEqual('nas.lan', HostHeaderName('NAS.lan:9000'));
  Assert.AreEqual('::1', HostHeaderName('[::1]:7777'));
  Assert.AreEqual('192.168.1.10', HostHeaderName(' 192.168.1.10:7777 '));
  Assert.AreEqual('example.com', HostHeaderName('example.com.'));
  Assert.AreEqual('', HostHeaderName(''));
end;

procedure TSecurityTests.AdminHostRule;
begin
  Assert.IsTrue(IsAllowedAdminHost('192.168.1.10:7777', '', []), 'IPv4 literal');
  Assert.IsTrue(IsAllowedAdminHost('[fd00::5]:7777', '', []), 'IPv6 literal');
  Assert.IsTrue(IsAllowedAdminHost('localhost:5173', '', []), 'localhost');
  Assert.IsTrue(IsAllowedAdminHost('nas', '', []), 'single-label');
  Assert.IsTrue(IsAllowedAdminHost('tower.local', '', []), '.local');
  Assert.IsTrue(IsAllowedAdminHost('box.lan:9000', '', []), '.lan');
  Assert.IsTrue(IsAllowedAdminHost('tv.home.arpa', '', []), '.home.arpa');
  Assert.IsTrue(IsAllowedAdminHost('iptv.internal', '', []), '.internal');
  Assert.IsTrue(IsAllowedAdminHost('', '', []), 'no Host header');
  Assert.IsFalse(IsAllowedAdminHost('evil.example.com', '', []), 'a public name');
  Assert.IsFalse(IsAllowedAdminHost('tower.local.evil.com', '', []), 'suffix must be at the end');
  Assert.IsTrue(IsAllowedAdminHost('iptv.example.org:9000', 'http://iptv.example.org:9000', []),
    'the publicBaseUrl host');
  Assert.IsTrue(IsAllowedAdminHost('IPTV.MyDomain.org:443', '', ['iptv.mydomain.org']), 'allowedHosts');
  Assert.IsFalse(IsAllowedAdminHost('other.mydomain.org', 'http://192.168.1.10:7777', ['iptv.mydomain.org']),
    'not listed');
end;

function FakeResolve(const AHost: string): string;
begin
  if SameText(AHost, cRebindHost) then
    Result := cRebindIp
  else
    Result := '';
end;

procedure TSecurityTests.RedirectGuard;
var
  lResolve: TFunc<string, string>;
begin
  lResolve :=
    function (AHost: string): string
    begin
      Result := FakeResolve(AHost);
    end;
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', '10.0.0.1', nil), 'to a private address');
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', '127.0.0.1', nil), 'to loopback');
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', 'localhost', nil), 'to localhost');
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', '169.254.169.254', nil), 'to link-local (metadata)');
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', '[::1]', nil), 'to IPv6 loopback');
  Assert.IsTrue(IsRedirectAllowed('provider.example.com', 'cdn.example.net', nil), 'public to public');
  Assert.IsTrue(IsRedirectAllowed('provider.example.com', '', nil), 'relative redirect');
  Assert.IsTrue(IsRedirectAllowed('192.168.1.50', '192.168.1.51', nil), 'a LAN provider may stay on the LAN');
  Assert.IsFalse(IsRedirectAllowed('provider.example.com', cRebindHost, lResolve), 'a name resolving inside');
end;

procedure TSecurityTests.BodyCap;
begin
  // (the default cap; the import route's own cap: BodyCapPerRoute)
  Assert.IsFalse(ContentLengthExceeds('', cMaxRequestBodyBytes), 'no header');
  Assert.IsFalse(ContentLengthExceeds('1024', cMaxRequestBodyBytes), 'small');
  Assert.IsFalse(ContentLengthExceeds(IntToStr(cMaxRequestBodyBytes), cMaxRequestBodyBytes), 'exactly the cap');
  Assert.IsTrue(ContentLengthExceeds(IntToStr(cMaxRequestBodyBytes + 1), cMaxRequestBodyBytes), 'above');
  Assert.IsTrue(ContentLengthExceeds('99999999999', cMaxRequestBodyBytes), 'huge');
  Assert.IsFalse(ContentLengthExceeds('abc', cMaxRequestBodyBytes), 'garbage is left to the server');
end;

procedure TSecurityTests.DownloadTokens;
const
  cPathA = '/api/lists/3/export.m3u';
  cPathB = '/api/lists/4/export.m3u';
var
  lTokens: TDownloadTokens;
  lToken, lOther: string;
begin
  lTokens := TDownloadTokens.Create;
  try
    lToken := lTokens.Issue(cPathA);
    lOther := lTokens.Issue(cPathB);
    Assert.AreEqual(cTokenRandomBytes * 2, Length(lToken), 'long random token');
    Assert.AreNotEqual(lToken, lOther, 'unique');
    Assert.IsTrue(lTokens.IsValid(lToken, cPathA), 'first use');
    Assert.IsTrue(lTokens.IsValid(lToken, cPathA), 'reusable within its lifetime (download managers)');
    Assert.IsTrue(lTokens.IsValid(lToken, cPathA + '?dt=' + lToken), 'the query is ignored');
    Assert.IsFalse(lTokens.IsValid(lToken, cPathB), 'bound to its path');
    Assert.IsFalse(lTokens.IsValid(lToken, '/api/export'), 'not the settings backup');
    Assert.IsFalse(lTokens.IsValid('nope', cPathA), 'unknown');
    Assert.IsFalse(lTokens.IsValid('', cPathA), 'empty');
    Assert.IsTrue(lTokens.IsValid(lOther, cPathB), 'the other one is independent');
  finally
    FreeAndNil(lTokens);
  end;
  // lifetime 0: expired at once
  lTokens := TDownloadTokens.Create(0);
  try
    Assert.IsFalse(lTokens.IsValid(lTokens.Issue(cPathA), cPathA), 'expired');
  finally
    FreeAndNil(lTokens);
  end;
end;

procedure TSecurityTests.DownloadTokenPaths;
begin
  Assert.IsTrue(IsDownloadTokenPath('/api/lists/12/export.m3u'), 'M3U export');
  Assert.IsTrue(IsDownloadTokenPath('/api/lists/1/export.xmltv'), 'XMLTV export');
  Assert.IsFalse(IsDownloadTokenPath('/api/export'), 'settings backup (all secrets)');
  Assert.IsFalse(IsDownloadTokenPath('/api/lists/x/export.m3u'), 'not a list id');
  Assert.IsFalse(IsDownloadTokenPath('/api/lists/12/export.m3u/../../export'), 'nothing appended');
  Assert.IsFalse(IsDownloadTokenPath('/api/config'), 'other route');
  Assert.IsFalse(IsDownloadTokenPath(''), 'empty');
  Assert.AreEqual('/api/lists/1/export.m3u', PathWithoutQuery('/api/lists/1/export.m3u?dt=x#y'));
end;

procedure TSecurityTests.SecureRandom;
const
  cRounds = 200;
var
  lSeen: TDictionary<string, Boolean>;
  lToken: string;
  i: Integer;
begin
  Assert.AreEqual(16, Length(SecureRandomBytes(16)), 'byte count');
  Assert.AreEqual(0, Length(SecureRandomBytes(0)), 'none');
  lSeen := TDictionary<string, Boolean>.Create;
  try
    for i := 1 to cRounds do
    begin
      lToken := SecureRandomHex;
      Assert.AreEqual(cTokenRandomBytes * 2, Length(lToken), 'hex length');
      Assert.IsTrue(TRegEx.IsMatch(lToken, '^[0-9a-f]+$'), 'lower-case hex');
      Assert.IsFalse(lSeen.ContainsKey(lToken), 'unique');
      lSeen.Add(lToken, True);
    end;
  finally
    FreeAndNil(lSeen);
  end;
end;

procedure TSecurityTests.Ipv4LeadingZeros;
begin
  Assert.IsFalse(IsIpLiteral('0177.0.0.1'), '0177 = 127 in octal');
  Assert.IsFalse(IsIpLiteral('10.010.0.1'), '010 = 8 in octal');
  Assert.IsFalse(IsPrivateAddress('010.0.0.1'), 'no address, so not private');
  Assert.IsTrue(IsIpLiteral('10.0.0.1'), 'a single 0 is fine');
  Assert.IsTrue(IsIpLiteral('100.64.0.0'), 'plain decimal');
  Assert.IsFalse(IsAllowedAdminHost('0177.0.0.1.evil.com', '', []), 'a name, not a literal');
end;

procedure TSecurityTests.CgnatIsPrivate;
begin
  Assert.IsTrue(IsPrivateAddress('100.64.0.1'), 'CGNAT low');
  Assert.IsTrue(IsPrivateAddress('100.101.102.103'), 'Tailscale address');
  Assert.IsTrue(IsPrivateAddress('100.127.255.255'), 'CGNAT high');
  Assert.IsFalse(IsPrivateAddress('100.128.0.1'), 'just above /10');
  Assert.IsFalse(IsPrivateAddress('100.63.255.255'), 'just below /10');
  Assert.IsTrue(IsPrivateAddress('::ffff:100.100.1.1'), 'mapped CGNAT');
  Assert.IsTrue(IsMediaClientPermitted('100.100.1.1', []), 'Tailscale client on the Plex surfaces');
end;

procedure TSecurityTests.AdminHostRuleHomeSuffixes;
begin
  Assert.IsTrue(IsAllowedAdminHost('fritz.box', '', []), '.box (FRITZ!Box)');
  Assert.IsTrue(IsAllowedAdminHost('nas.fritz.box:7777', '', []), 'name under fritz.box');
  Assert.IsTrue(IsAllowedAdminHost('tower.home', '', []), '.home');
  Assert.IsTrue(IsAllowedAdminHost('tower.localdomain', '', []), '.localdomain');
  Assert.IsTrue(IsAllowedAdminHost('tower.tail1234.ts.net', '', []), 'Tailscale MagicDNS');
  Assert.IsTrue(IsAllowedAdminHost('abc.myunraid.net:443', '', []), 'Unraid Connect');
  Assert.IsFalse(IsAllowedAdminHost('evilbox.com', '', []), 'suffix needs the dot');
  Assert.IsFalse(IsAllowedAdminHost('ts.net.evil.com', '', []), 'suffix must be at the end');
end;

procedure TSecurityTests.HostsKeptOnImport;
var
  lHosts: TArray<string>;
begin
  lHosts := HostsKeepingCurrent('iptv.example.org:9000', '', []);
  Assert.AreEqual(1, Length(lHosts), 'added');
  Assert.AreEqual('iptv.example.org', lHosts[0], 'host name only');
  lHosts := HostsKeepingCurrent('iptv.example.org', '', ['iptv.example.org']);
  Assert.AreEqual(1, Length(lHosts), 'already listed: unchanged');
  lHosts := HostsKeepingCurrent('192.168.1.10:7777', '', ['a.example']);
  Assert.AreEqual(1, Length(lHosts), 'an IP passes anyway: unchanged');
  lHosts := HostsKeepingCurrent('iptv.example.org', 'http://iptv.example.org:9000', []);
  Assert.AreEqual(0, Length(lHosts), 'allowed by publicBaseUrl: unchanged');
  lHosts := HostsKeepingCurrent('', '', []);
  Assert.AreEqual(0, Length(lHosts), 'no Host');
end;

function Bytes(const AText: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(AText);
end;

procedure TSecurityTests.JsonDepth;
begin
  Assert.IsFalse(JsonNestingExceeds(Bytes('{"a":[1,{"b":2}]}'), 3), 'depth 3 at max 3');
  Assert.IsTrue(JsonNestingExceeds(Bytes('{"a":[1,{"b":[2]}]}'), 3), 'depth 4 above 3');
  Assert.IsFalse(JsonNestingExceeds(Bytes('{"a":"[[[[[[[[["}'), 2), 'brackets in a string');
  Assert.IsFalse(JsonNestingExceeds(Bytes('{"a":"\"[[[[[[["}'), 2), 'escaped quote stays in the string');
  Assert.IsFalse(JsonNestingExceeds(Bytes('{"a":"x\\"}'), 1), 'an escaped backslash ends the escape');
  Assert.IsTrue(JsonNestingExceeds(Bytes('{"a":"x\\",' + '"b":[[1]]}'), 2), 'counted after it');
  Assert.IsFalse(JsonNestingExceeds(Bytes('[][][][][]'), 1), 'siblings are not nesting');
  Assert.IsTrue(JsonNestingExceeds(Bytes(StringOfChar('[', cMaxJsonDepth + 1)), cMaxJsonDepth), 'a bomb');
  Assert.IsFalse(JsonNestingExceeds(Bytes(StringOfChar('[', cMaxJsonDepth)), cMaxJsonDepth), 'exactly the max');
  Assert.IsFalse(JsonNestingExceeds(nil, cMaxJsonDepth), 'no body');
end;

procedure TSecurityTests.BodyCapPerRoute;
begin
  Assert.AreEqual(cMaxRequestBodyBytes, MaxBodyBytesFor('/api/config'), 'default');
  Assert.AreEqual(Int64(1024 * 1024), cMaxRequestBodyBytes, '1 MB');
  Assert.AreEqual(cMaxImportBodyBytes, MaxBodyBytesFor('/api/import'), 'settings import');
  Assert.AreEqual(cMaxImportBodyBytes, MaxBodyBytesFor('/API/Import/?x=1'), 'case, slash, query');
  Assert.AreEqual(cMaxImportBodyBytes, MaxBodyBytesFor('http://nas:7777/api/import'), 'absolute form');
  Assert.AreEqual(cMaxRequestBodyBytes, MaxBodyBytesFor('/api/import2'), 'not a prefix match');
  Assert.AreEqual(cMaxRequestBodyBytes, MaxBodyBytesFor('/api/sources?x=/api/import'), 'not in the query');
end;

procedure TSecurityTests.WarmupToken;
var
  lSaved: string;
begin
  lSaved := GWarmToken;
  try
    GWarmToken := '';
    Assert.IsFalse(IsWarmupRequest('anything'), 'no warm-up running');
    Assert.IsFalse(IsWarmupRequest(''), 'empty');
    NewWarmupToken;
    Assert.AreEqual(cTokenRandomBytes * 2, Length(GWarmToken), 'random token');
    Assert.IsTrue(IsWarmupRequest(GWarmToken), 'the exact token');
    Assert.IsFalse(IsWarmupRequest('1'), 'any non-empty value is NOT enough');
    Assert.IsFalse(IsWarmupRequest(''), 'empty never');
  finally
    GWarmToken := lSaved;
  end;
end;

procedure TSecurityTests.RealLoginNames;
begin
  Assert.IsFalse(IsRealLoginName(''), 'empty');
  Assert.IsFalse(IsRealLoginName('-'), 'the PathCred placeholder');
  Assert.IsFalse(IsRealLoginName(' - '), 'trimmed');
  Assert.IsTrue(IsRealLoginName('box1'), 'a login');
end;

procedure TSecurityTests.Ipv6KeyedBy64;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
  i: Integer;
begin
  Assert.AreEqual('2001:db8:1:2::/64', ClientAddressKey('2001:db8:1:2:aaaa:bbbb:cccc:dddd'));
  Assert.AreEqual('2001:db8:1:2::/64', ClientAddressKey('[2001:0db8:0001:0002::1]'));
  Assert.AreEqual('fe80:0:0:0::/64', ClientAddressKey('fe80::1%eth0'));
  Assert.AreEqual('192.168.1.5', ClientAddressKey('::ffff:192.168.1.5'), 'mapped = IPv4');
  Assert.AreEqual('10.0.0.1', ClientAddressKey(' 10.0.0.1 '), 'IPv4 as is');
  Assert.AreEqual('garbage', ClientAddressKey('garbage'), 'non-IP as is');
  lThrottle := TAuthThrottle.Create(cAuthMaxFailures, cTestWindowSec, cTestLockoutSec);
  try
    // a guesser rotating through its /64 still hits one key
    for i := 1 to cAuthMaxFailures do
      lThrottle.RegisterFailure(lThrottle.ClientKey(cSurfaceAdmin, '2001:db8:1:2::' + IntToHex(i, 1), ''));
    Assert.IsTrue(lThrottle.IsBlocked(lThrottle.ClientKey(cSurfaceAdmin, '2001:db8:1:2::ffff', ''), lRetryAfter),
      'the whole /64 is locked out');
    Assert.IsFalse(lThrottle.IsBlocked(lThrottle.ClientKey(cSurfaceAdmin, '2001:db8:1:3::1', ''), lRetryAfter),
      'another /64 is not');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.ForwardedForLinesJoined;
var
  lThrottle: TAuthThrottle;
begin
  Assert.AreEqual('1.1.1.1, 203.0.113.7', JoinForwardedFor(['1.1.1.1', ' 203.0.113.7 ']), 'joined in order');
  Assert.AreEqual('a, b', JoinForwardedFor(['', 'a', '  ', 'b']), 'blank lines dropped');
  Assert.AreEqual('', JoinForwardedFor([]), 'none');
  lThrottle := TAuthThrottle.Create(cAuthMaxFailures, cTestWindowSec, cTestLockoutSec);
  try
    lThrottle.TrustedProxies := [cProxyA];
    // the client sent its own X-Forwarded-For line; our proxy added a second line: the
    // walk must start at the proxy's (last) line, not at the client's first one
    Assert.AreEqual(cRealClient,
      lThrottle.ClientAddress(cProxyA, JoinForwardedFor([cSpoofed, cRealClient])), 'last line counts');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.LocalClientRule;
var
  lThrottle: TAuthThrottle;
begin
  lThrottle := TAuthThrottle.Create(cAuthMaxFailures, cTestWindowSec, cTestLockoutSec);
  try
    Assert.IsTrue(lThrottle.IsLocalClient('192.168.1.20', ''), 'LAN client');
    Assert.IsTrue(lThrottle.IsLocalClient('100.101.1.2', ''), 'Tailscale client');
    Assert.IsFalse(lThrottle.IsLocalClient(cRealClient, ''), 'internet client');
    Assert.IsFalse(lThrottle.IsLocalClient(cRealClient, '192.168.1.5'), 'a forged XFF from outside');
    // a LAN reverse proxy that is NOT trusted, forwarding an internet client
    Assert.IsFalse(lThrottle.IsLocalClient(cProxyA, cRealClient), 'untrusted LAN proxy for the internet');
    Assert.IsTrue(lThrottle.IsLocalClient(cProxyA, '192.168.1.77'), 'untrusted LAN proxy for a LAN client');
    lThrottle.TrustedProxies := [cProxyA];
    Assert.IsFalse(lThrottle.IsLocalClient(cProxyA, cRealClient), 'trusted proxy: its internet client');
    Assert.IsTrue(lThrottle.IsLocalClient(cProxyA, '192.168.1.77'), 'trusted proxy: its LAN client');
    Assert.IsTrue(lThrottle.IsLocalClient(cProxyA, ''), 'the proxy itself');
    Assert.AreEqual(cRealClient, lThrottle.ClientAddress(cProxyA, cRealClient), 'client through the proxy');
    Assert.AreEqual(cProxyB, lThrottle.ClientAddress(cProxyB, cRealClient), 'untrusted peer counts as itself');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.MaskedUrlListRestore;
const
  cStoredA = 'https://epg.example.com/guide.xml?apikey=SECRET&x=1';
  cStoredB = 'https://other.example.net/g.xml?token=T2';
var
  lOut: TArray<string>;
begin
  // same order, masked value comes back: restored
  lOut := RestoreMaskedUrlList(['https://epg.example.com/guide.xml?apikey=***&x=1'], [cStoredA]);
  Assert.AreEqual(cStoredA, lOut[0], 'restored by index');
  // reordered: matched by the URL without query
  lOut := RestoreMaskedUrlList(['https://other.example.net/g.xml?token=***',
    'https://epg.example.com/guide.xml?apikey=***&x=1'], [cStoredA, cStoredB]);
  Assert.AreEqual(cStoredB, lOut[0], 'matched by base URL');
  Assert.AreEqual(cStoredA, lOut[1], 'matched by base URL (2)');
  // index points at another host: never move the secret over
  lOut := RestoreMaskedUrlList(['https://evil.example.org/g.xml?apikey=***'], [cStoredA]);
  Assert.IsFalse(lOut[0].Contains('SECRET'), 'no secret onto another host');
  // a new value is kept
  lOut := RestoreMaskedUrlList(['https://epg.example.com/guide.xml?apikey=NEW&x=1'], [cStoredA]);
  Assert.AreEqual('https://epg.example.com/guide.xml?apikey=NEW&x=1', lOut[0], 'new secret kept');
end;

procedure TSecurityTests.ForwardedForRightMost;
var
  lThrottle: TAuthThrottle;
begin
  lThrottle := TAuthThrottle.Create(cAuthMaxFailures, cTestWindowSec, cTestLockoutSec);
  try
    lThrottle.TrustedProxies := [cProxyA, cProxyB];
    // the client forged a left-most entry; our proxy appended the real address
    Assert.AreEqual(cSurfaceBox + ':' + cRealClient,
      lThrottle.ClientKey(cSurfaceBox, cProxyA, cSpoofed + ', ' + cRealClient), 'right-most, not the forged one');
    // two of our own proxies in the chain are skipped
    Assert.AreEqual(cSurfaceBox + ':' + cRealClient,
      lThrottle.ClientKey(cSurfaceBox, cProxyA, cSpoofed + ', ' + cRealClient + ', ' + cProxyB),
      'trusted hops skipped');
    // a fresh forged value per request can't give a fresh key
    Assert.AreEqual(lThrottle.ClientKey(cSurfaceBox, cProxyA, 'x1, ' + cRealClient),
      lThrottle.ClientKey(cSurfaceBox, cProxyA, 'x2, ' + cRealClient), 'same key whatever is forged');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.OverflowKeepsLockouts;
const
  cMaxFailures = 3;
  cMaxEntries = 4;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
  i: Integer;
begin
  lThrottle := TAuthThrottle.Create(cMaxFailures, cTestWindowSec, cTestLockoutSec, cMaxEntries);
  try
    for i := 1 to cMaxFailures do
      lThrottle.RegisterFailure('blocked');
    Assert.IsTrue(lThrottle.IsBlocked('blocked', lRetryAfter), 'locked out');
    // fill the table and overflow it with fresh keys (a flood of new IPs)
    for i := 1 to cMaxEntries * 3 do
      lThrottle.RegisterFailure('fresh' + IntToStr(i));
    Assert.IsTrue(lThrottle.IsBlocked('blocked', lRetryAfter), 'a flood of new keys never lifts a lockout');
    // the newest key is still counted (room was made by evicting counting entries)
    for i := 2 to cMaxFailures do
      lThrottle.RegisterFailure('fresh' + IntToStr(cMaxEntries * 3));
    Assert.IsTrue(lThrottle.IsBlocked('fresh' + IntToStr(cMaxEntries * 3), lRetryAfter), 'new key tracked');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.OverflowFullOfLockouts;
const
  cMaxFailures = 1; // every failure locks out
  cMaxEntries = 2;
var
  lThrottle: TAuthThrottle;
  lRetryAfter: Integer;
begin
  lThrottle := TAuthThrottle.Create(cMaxFailures, cTestWindowSec, cTestLockoutSec, cMaxEntries);
  try
    lThrottle.RegisterFailure('a');
    lThrottle.RegisterFailure('b');
    lThrottle.RegisterFailure('c'); // no room: not tracked
    Assert.IsTrue(lThrottle.IsBlocked('a', lRetryAfter), 'a stays locked out');
    Assert.IsTrue(lThrottle.IsBlocked('b', lRetryAfter), 'b stays locked out');
    Assert.IsFalse(lThrottle.IsBlocked('c', lRetryAfter), 'c was not tracked (the table was not cleared)');
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TSecurityTests.SourcePasswordWriteOnly;
var
  lSource: TSourceConfig;
  lJson, lBody: TJSONObject;
begin
  lJson := nil;
  lBody := nil;
  lSource := TSourceConfig.Create;
  try
    lSource.Password := 'secret';
    lJson := SourceToAdminJson(lSource);
    Assert.AreEqual('', lJson.GetValue<string>('password'), 'never sent to the browser');
    Assert.IsTrue(lJson.GetValue<Boolean>('hasPassword'), 'but flagged as set');
    // a body without the key (the web app didn't touch the field) keeps it
    lBody := TJSONObject.Create.AddPair('name', 'renamed');
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('secret', lSource.Password, 'no key = keep');
    FreeAndNil(lBody);
    lBody := TJSONObject.Create.AddPair('clearPassword', TJSONBool.Create(True));
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('', lSource.Password, 'clearPassword clears it ("" keeps it, see Test.Serializers)');
    FreeAndNil(lJson);
    lJson := SourceToAdminJson(lSource);
    Assert.IsFalse(lJson.GetValue<Boolean>('hasPassword'), 'none stored');
  finally
    FreeAndNil(lBody);
    FreeAndNil(lJson);
    FreeAndNil(lSource);
  end;
end;

procedure TSecurityTests.MirrorPasswordWriteOnly;
const
  cSourceKept = 1;
  cSourceSet = 2;
var
  lStored: TArray<TMirrorCredential>;
  lParsed: TArray<TMirrorCredential>;
  lArray: TJSONArray;
begin
  SetLength(lStored, 2);
  lStored[0].SourceId := cSourceKept;
  lStored[0].Password := 'old1';
  lStored[1].SourceId := cSourceSet;
  lStored[1].Password := 'old2';
  lArray := MirrorCredentialsToJson(lStored);
  try
    Assert.AreEqual('', (lArray.Items[0] as TJSONObject).GetValue<string>('password'), 'write-only');
    Assert.IsTrue((lArray.Items[0] as TJSONObject).GetValue<Boolean>('hasPassword'), 'flagged');
  finally
    FreeAndNil(lArray);
  end;
  lArray := TJSONArray.Create;
  try
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cSourceKept))
      .AddPair('username', 'u1'));
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cSourceSet))
      .AddPair('password', 'new2'));
    lParsed := MirrorCredentialsFromJson(lArray, lStored);
    Assert.AreEqual(2, Length(lParsed));
    Assert.AreEqual('old1', lParsed[0].Password, 'no key = the stored password');
    Assert.AreEqual('u1', lParsed[0].Username);
    Assert.AreEqual('new2', lParsed[1].Password, 'a present key sets it');
  finally
    FreeAndNil(lArray);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSecurityTests);

end.
