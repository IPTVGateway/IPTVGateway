unit Test.Relay;

{ Tests for IPTV.Api.RelayRules: the stream relay's id / extension parsing, send
  timeouts, the portal-route bounce target, the body refusal and the upstream /
  redirect guard. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for IPTV.Api.RelayRules.</summary>
  [TestFixture]
  TRelayRulesTests = class
  public
    /// <summary>The id is digits only; the extension only ts / m3u8.</summary>
    [Test] procedure IdPart_DigitsAndKnownExtensionsOnly;
    /// <summary>Path tricks in the extension never survive.</summary>
    [Test] procedure IdPart_ExtensionTricksAreDropped;
    /// <summary>Live gets the short send timeout, VOD and archives the long one.</summary>
    [Test] procedure SendTimeout_LiveShortVodLong;
    /// <summary>A usable publicBaseUrl decides the bounce target.</summary>
    [Test] procedure Bounce_UsesPublicBaseUrl;
    /// <summary>Without one a LAN Host header is kept, a foreign one replaced.</summary>
    [Test] procedure Bounce_ForeignHostHeaderIsIgnored;
    /// <summary>Any body is refused: 413 for a length, 411 for chunked.</summary>
    [Test] procedure Body_AnyBodyRefused;
    /// <summary>Loopback addresses in all spellings are recognised.</summary>
    [Test] procedure Loopback_Detection;
    /// <summary>A name resolving to loopback counts as loopback.</summary>
    [Test] procedure Loopback_ViaResolver;
    /// <summary>The first upstream URL: http(s) only, never loopback.</summary>
    [Test] procedure Upstream_LoopbackRefused;
    /// <summary>Redirects: no loopback (even from a LAN provider), no other scheme.</summary>
    [Test] procedure Redirect_Guard;
    [Test] procedure Peer_Rule;
    [Test] procedure ConfiguredInternalHost_Rule;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Model.Types,
  IPTV.Api.RelayRules;

const
  cPath = '/player_api.php?username=u&password=p';

procedure TRelayRulesTests.IdPart_DigitsAndKnownExtensionsOnly;
var
  lId: Integer;
  lExt: string;
begin
  Assert.IsTrue(ParseRelayIdPart('123', lId, lExt));
  Assert.AreEqual(123, lId);
  Assert.AreEqual('', lExt);
  Assert.IsTrue(ParseRelayIdPart('45.ts', lId, lExt));
  Assert.AreEqual(45, lId);
  Assert.AreEqual('ts', lExt);
  Assert.IsTrue(ParseRelayIdPart('45.M3U8', lId, lExt));
  Assert.AreEqual('m3u8', lExt);
  Assert.IsTrue(ParseRelayIdPart('45.mp4', lId, lExt));
  Assert.AreEqual('', lExt, 'an unknown extension is dropped');
  Assert.IsFalse(ParseRelayIdPart('$1F', lId, lExt), 'no hex');
  Assert.IsFalse(ParseRelayIdPart('+12', lId, lExt));
  Assert.IsFalse(ParseRelayIdPart('12a.ts', lId, lExt));
  Assert.IsFalse(ParseRelayIdPart('', lId, lExt));
  Assert.IsFalse(ParseRelayIdPart('0', lId, lExt));
  Assert.IsFalse(ParseRelayIdPart('99999999999', lId, lExt), 'overflow');
end;

procedure TRelayRulesTests.IdPart_ExtensionTricksAreDropped;
var
  lId: Integer;
  lExt: string;
begin
  Assert.IsTrue(ParseRelayIdPart('12.ts/../../99', lId, lExt));
  Assert.AreEqual(12, lId);
  Assert.AreEqual('', lExt);
  Assert.IsTrue(ParseRelayIdPart('12.ts?x=1', lId, lExt));
  Assert.AreEqual('', lExt);
  Assert.IsTrue(ParseRelayIdPart('12.x.m3u8', lId, lExt));
  Assert.AreEqual('', lExt);
  Assert.IsFalse(ParseRelayIdPart('../12.ts', lId, lExt));
end;

procedure TRelayRulesTests.SendTimeout_LiveShortVodLong;
begin
  Assert.AreEqual(cRelaySendTimeoutLiveMs, RelaySendTimeoutMs(ctLive, False));
  Assert.AreEqual(cRelaySendTimeoutVodMs, RelaySendTimeoutMs(ctLive, True), 'an archive can be paused');
  Assert.AreEqual(cRelaySendTimeoutVodMs, RelaySendTimeoutMs(ctMovie, False));
  Assert.AreEqual(cRelaySendTimeoutVodMs, RelaySendTimeoutMs(ctSeries, False));
end;

procedure TRelayRulesTests.Bounce_UsesPublicBaseUrl;
begin
  Assert.AreEqual('https://tv.example.com:9443' + cPath,
    RelayApiBounceUrl('https://tv.example.com:9443/', [], 'evil.com', '10.0.0.5', False, 7777, cPath));
  Assert.AreEqual('http://192.168.1.250:9000' + cPath,
    RelayApiBounceUrl('http://192.168.1.250:9000', [], '', '', False, 7777, cPath));
  Assert.AreEqual('https://example.com/iptv' + cPath,
    RelayApiBounceUrl('https://example.com/iptv', [], '', '', False, 7777, cPath), 'path prefix kept');
  Assert.IsFalse(IsUsablePublicBaseUrl(''));
  Assert.IsFalse(IsUsablePublicBaseUrl('http://your-unraid-host:7777'));
  Assert.IsFalse(IsUsablePublicBaseUrl('http://localhost:7777'));
  Assert.IsFalse(IsUsablePublicBaseUrl('ftp://nas.lan'));
  Assert.IsTrue(IsUsablePublicBaseUrl('http://nas.lan:7777'));
end;

procedure TRelayRulesTests.Bounce_ForeignHostHeaderIsIgnored;
begin
  // the template placeholder / localhost default: fall back to Host or the listen address
  Assert.AreEqual('http://192.168.1.10:7777' + cPath,
    RelayApiBounceUrl('http://localhost:7777', [], '192.168.1.10:7778', '10.0.0.5', False, 7777, cPath));
  Assert.AreEqual('http://nas.lan:7777' + cPath,
    RelayApiBounceUrl('', [], 'NAS.lan:7778', '10.0.0.5', False, 7777, cPath));
  Assert.AreEqual('https://10.0.0.5:7777' + cPath,
    RelayApiBounceUrl('', [], 'evil.example.com', '10.0.0.5', True, 7777, cPath), 'foreign Host ignored');
  Assert.AreEqual('http://tv.example.com:7777' + cPath,
    RelayApiBounceUrl('', ['tv.example.com'], 'tv.example.com:7778', '10.0.0.5', False, 7777, cPath),
    'an allowed host is kept');
  Assert.AreEqual('http://10.0.0.5:7777' + cPath,
    RelayApiBounceUrl('', [], 'user@evil', '10.0.0.5', False, 7777, cPath), 'no userinfo trick');
  Assert.AreEqual('http://[fd00::5]:7777' + cPath,
    RelayApiBounceUrl('', [], 'bad host/x', 'fd00::5', False, 7777, cPath));
  Assert.AreEqual('http://localhost:7777' + cPath,
    RelayApiBounceUrl('', [], '', '0.0.0.0', False, 7777, cPath));
end;

procedure TRelayRulesTests.Body_AnyBodyRefused;
begin
  Assert.AreEqual(0, RelayBodyRefusal('', ''));
  Assert.AreEqual(0, RelayBodyRefusal('0', ''));
  Assert.AreEqual(cHttpRelayPayloadTooLarge, RelayBodyRefusal('1', ''));
  Assert.AreEqual(cHttpRelayPayloadTooLarge, RelayBodyRefusal('abc', ''), 'an untrusted length');
  Assert.AreEqual(cHttpLengthRequired, RelayBodyRefusal('', 'chunked'));
  Assert.AreEqual(cHttpLengthRequired, RelayBodyRefusal('0', 'chunked'));
end;

procedure TRelayRulesTests.Loopback_Detection;
begin
  Assert.IsTrue(IsLoopbackHost('127.0.0.1'));
  Assert.IsTrue(IsLoopbackHost('127.8.9.10'));
  Assert.IsTrue(IsLoopbackHost('0.0.0.0'));
  Assert.IsTrue(IsLoopbackHost('localhost'));
  Assert.IsTrue(IsLoopbackHost('LOCALHOST.'));
  Assert.IsTrue(IsLoopbackHost('a.localhost'));
  Assert.IsTrue(IsLoopbackHost('::1'));
  Assert.IsTrue(IsLoopbackHost('[::1]'));
  Assert.IsTrue(IsLoopbackHost('0:0:0:0:0:0:0:1'));
  Assert.IsTrue(IsLoopbackHost('::'));
  Assert.IsTrue(IsLoopbackHost('::ffff:127.0.0.1'));
  Assert.IsTrue(IsLoopbackHost('::ffff:7f00:1'));
  Assert.IsFalse(IsLoopbackHost('192.168.1.1'));
  Assert.IsFalse(IsLoopbackHost('10.0.0.1'));
  Assert.IsFalse(IsLoopbackHost('::2'));
  Assert.IsFalse(IsLoopbackHost('fe80::1'));
  Assert.IsFalse(IsLoopbackHost('::ffff:8.8.8.8'));
  Assert.IsFalse(IsLoopbackHost('example.com'));
  Assert.IsFalse(IsLoopbackHost('0177.0.0.1'), 'not a literal: left to the resolver');
end;

procedure TRelayRulesTests.Loopback_ViaResolver;
var
  lResolve: TFunc<string, string>;
begin
  lResolve :=
    function(AHost: string): string
    begin
      if (AHost = 'evil.example') or (AHost = '0177.0.0.1') or (AHost = '2130706433') then
        Result := '127.0.0.1'
      else if AHost = 'boom' then
        raise Exception.Create('lookup failed')
      else
        Result := '93.184.216.34';
    end;
  Assert.IsTrue(HostResolvesToLoopback('evil.example', lResolve));
  Assert.IsTrue(HostResolvesToLoopback('0177.0.0.1', lResolve));
  Assert.IsTrue(HostResolvesToLoopback('2130706433', lResolve));
  Assert.IsFalse(HostResolvesToLoopback('provider.example', lResolve));
  Assert.IsFalse(HostResolvesToLoopback('boom', lResolve));
  Assert.IsFalse(HostResolvesToLoopback('evil.example', nil), 'without a resolver names are public');
end;

procedure TRelayRulesTests.Upstream_LoopbackRefused;
begin
  Assert.IsTrue(IsRelayUpstreamAllowed('http://provider.example:8080/live/u/p/1.ts', nil));
  Assert.IsTrue(IsRelayUpstreamAllowed('http://192.168.1.20/live/u/p/1.ts', nil), 'a LAN provider is fine');
  Assert.IsFalse(IsRelayUpstreamAllowed('http://127.0.0.1:7777/api/settings', nil));
  Assert.IsFalse(IsRelayUpstreamAllowed('http://localhost:7777/x', nil));
  Assert.IsFalse(IsRelayUpstreamAllowed('http://[::1]:7777/x', nil));
  Assert.IsFalse(IsRelayUpstreamAllowed('http://user:pw@127.0.0.1/x', nil), 'userinfo is not the host');
  Assert.IsFalse(IsRelayUpstreamAllowed('file:///etc/passwd', nil));
  Assert.IsFalse(IsRelayUpstreamAllowed('/relative', nil));
end;

procedure TRelayRulesTests.Redirect_Guard;
begin
  Assert.IsTrue(IsRelayRedirectAllowed('provider.example', 'http://node2.example/x.ts', nil));
  Assert.IsTrue(IsRelayRedirectAllowed('provider.example', '/other/path.ts', nil), 'relative');
  Assert.IsFalse(IsRelayRedirectAllowed('provider.example', 'http://192.168.1.1/admin', nil),
    'public -> private');
  Assert.IsTrue(IsRelayRedirectAllowed('192.168.1.20', 'http://192.168.1.21/x.ts', nil), 'LAN -> LAN');
  Assert.IsFalse(IsRelayRedirectAllowed('192.168.1.20', 'http://127.0.0.1:7777/api', nil),
    'never loopback, even from a LAN provider');
  Assert.IsFalse(IsRelayRedirectAllowed('127.0.0.1', 'http://localhost/x', nil));
  Assert.IsFalse(IsRelayRedirectAllowed('provider.example', '//127.0.0.1/x', nil), 'protocol-relative');
  Assert.IsFalse(IsRelayRedirectAllowed('provider.example', 'ftp://node.example/x', nil));
  Assert.IsFalse(IsRelayRedirectAllowed('provider.example', 'file:///etc/passwd', nil));
  Assert.IsFalse(IsRelayRedirectAllowed('provider.example', 'http://evil@[::1]/x', nil));
end;

procedure TRelayRulesTests.Peer_Rule;
begin
  Assert.IsTrue(IsRelayPeerAllowed('93.184.216.34', False), 'public peer');
  Assert.IsFalse(IsRelayPeerAllowed('192.168.1.5', False), 'LAN peer for a public provider');
  Assert.IsTrue(IsRelayPeerAllowed('192.168.1.5', True), 'LAN peer for a LAN provider');
  Assert.IsFalse(IsRelayPeerAllowed('127.0.0.1', True), 'never loopback');
  Assert.IsFalse(IsRelayPeerAllowed('::1', True), 'never loopback (IPv6)');
  Assert.IsFalse(IsRelayPeerAllowed('::ffff:127.0.0.1', True), 'never loopback (mapped)');
  Assert.IsFalse(IsRelayPeerAllowed('', True), 'unknown peer');
end;

procedure TRelayRulesTests.ConfiguredInternalHost_Rule;
var
  lHosts: TArray<string>;
begin
  lHosts := ['provider.example', '192.168.1.20'];
  Assert.IsTrue(IsConfiguredInternalHost('192.168.1.20', lHosts, nil), 'configured LAN provider');
  Assert.IsFalse(IsConfiguredInternalHost('192.168.1.99', lHosts, nil), 'LAN host only from playlist content');
  Assert.IsFalse(IsConfiguredInternalHost('provider.example', lHosts, nil), 'configured public provider');
  Assert.IsFalse(IsConfiguredInternalHost('', lHosts, nil));
end;

initialization
  TDUnitX.RegisterTestFixture(TRelayRulesTests);

end.
