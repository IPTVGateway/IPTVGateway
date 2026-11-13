unit Test.Stalker;

{ Unit tests for the Stalker/MAG portal URL + header builders. The live catalog
  flow needs a real portal (and is covered by the opt-in live test, if ever), but
  the deterministic URL/cookie construction is verified here without a network. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for the Stalker/MAG portal URL and cookie builders.</summary>
  [TestFixture]
  TStalkerTests = class
  public
    /// <summary>A bare host gets /portal.php appended.</summary>
    [Test] procedure PortalUrl_AppendsPortalPhp;
    /// <summary>A /c/ console path resolves to the portal endpoint.</summary>
    [Test] procedure PortalUrl_StripsConsolePath;
    /// <summary>An explicit endpoint URL is kept.</summary>
    [Test] procedure PortalUrl_KeepsExplicitEndpoint;
    /// <summary>The handshake action URL is built correctly.</summary>
    [Test] procedure ActionUrl_BuildsHandshake;
    /// <summary>The cookie carries the MAC, language and timezone.</summary>
    [Test] procedure Cookie_CarriesMacAndLocale;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Source.Stalker;

procedure TStalkerTests.PortalUrl_AppendsPortalPhp;
begin
  Assert.AreEqual('http://host:8080/portal.php', StalkerPortalUrl('http://host:8080'));
  Assert.AreEqual('http://host:8080/portal.php', StalkerPortalUrl('http://host:8080/'));
end;

procedure TStalkerTests.PortalUrl_StripsConsolePath;
begin
  // a /c/ console URL resolves to the portal endpoint
  Assert.AreEqual('http://host/portal.php', StalkerPortalUrl('http://host/c'));
  Assert.AreEqual('http://host/portal.php', StalkerPortalUrl('http://host/c/'));
end;

procedure TStalkerTests.PortalUrl_KeepsExplicitEndpoint;
begin
  Assert.AreEqual('http://host/stalker_portal/server/load.php',
    StalkerPortalUrl('http://host/stalker_portal/server/load.php'));
  Assert.AreEqual('http://host/portal.php', StalkerPortalUrl('http://host/portal.php/'));
end;

procedure TStalkerTests.ActionUrl_BuildsHandshake;
begin
  Assert.AreEqual(
    'http://host/portal.php?type=stb&action=handshake&token=&JsHttpRequest=1-xml',
    StalkerActionUrl('http://host/portal.php', 'stb', 'handshake', '&token='));
end;

procedure TStalkerTests.Cookie_CarriesMacAndLocale;
var
  lCookie: string;
begin
  lCookie := StalkerCookie('00:1A:79:AA:BB:CC');
  Assert.IsTrue(lCookie.Contains('mac=00:1A:79:AA:BB:CC'), 'cookie carries the MAC');
  Assert.IsTrue(lCookie.Contains('stb_lang=en'), 'cookie carries stb_lang');
  Assert.IsTrue(lCookie.Contains('timezone='), 'cookie carries timezone');
end;

initialization
  TDUnitX.RegisterTestFixture(TStalkerTests);

end.
