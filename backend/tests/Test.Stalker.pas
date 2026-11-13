unit Test.Stalker;

{ Unit tests for the Stalker/MAG portal URL + header builders. The live catalog
  flow needs a real portal (and is covered by the opt-in live test, if ever), but
  the deterministic URL/cookie construction is verified here without a network. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStalkerTests = class
  public
    [Test] procedure PortalUrl_AppendsPortalPhp;
    [Test] procedure PortalUrl_StripsConsolePath;
    [Test] procedure PortalUrl_KeepsExplicitEndpoint;
    [Test] procedure ActionUrl_BuildsHandshake;
    [Test] procedure Cookie_CarriesMacAndLocale;
  end;

implementation

uses
  System.SysUtils,
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
  C: string;
begin
  C := StalkerCookie('00:1A:79:AA:BB:CC');
  Assert.IsTrue(C.Contains('mac=00:1A:79:AA:BB:CC'), 'cookie carries the MAC');
  Assert.IsTrue(C.Contains('stb_lang=en'), 'cookie carries stb_lang');
  Assert.IsTrue(C.Contains('timezone='), 'cookie carries timezone');
end;

initialization
  TDUnitX.RegisterTestFixture(TStalkerTests);

end.
