unit Test.SourceHttp;

{ Tests the shared HTTP fetch (IPTV.Source.Http). The http path goes through Indy
  (lenient — the whole reason for the hybrid), which we verify end-to-end against
  a throwaway local TIdHTTPServer. No external network. }

interface

uses
  DUnitX.TestFramework,
  IdCustomHTTPServer, IdContext;

type
  [TestFixture]
  TSourceHttpTests = class
  private
    FServer: TObject; // TIdHTTPServer (kept opaque in the interface)
    FPort: Integer;
    FFlakyHits: Integer; // counts hits on /flaky to exercise 503 backoff
    procedure DoGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure HttpGetString_FetchesViaIndy;
    [Test] procedure HttpGetString_FollowsToBodyForJson;
    [Test] procedure CloudflareChallenge_RaisesProviderBlocked;
    [Test] procedure DecodeBytes_HonoursUtf8Bom;
    [Test] procedure DecodeBytes_AcceptsPlainUtf8;
    [Test] procedure DecodeBytes_FallsBackToCp1251;
    [Test] procedure DecodeBytes_KeepsEmoji;
    [Test] procedure ForwardsUserAgentAndReferer;
    [Test] procedure SendsConnectionCloseAndIdentityEncoding;
    [Test] procedure RetriesOn503ThenSucceeds;
  end;

implementation

uses
  System.SysUtils, System.Classes,
  IdHTTPServer,
  IPTV.Source.Http;

procedure TSourceHttpTests.DoGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
begin
  if ARequestInfo.Document = '/cf' then
  begin
    // emulate a Cloudflare JS-challenge interstitial (403 + challenge markers)
    AResponseInfo.ResponseNo := 403;
    AResponseInfo.ContentType := 'text/html';
    AResponseInfo.ContentText :=
      '<html><head><title>Just a moment...</title></head>' +
      '<body>__cf_chl_jschl_tk__</body></html>';
    Exit;
  end;
  if ARequestInfo.Document = '/flaky' then
  begin
    Inc(FFlakyHits);
    if FFlakyHits = 1 then
    begin
      // first hit is rate-limited; the client should back off and retry
      AResponseInfo.ResponseNo := 503;
      AResponseInfo.ContentText := 'busy';
      Exit;
    end;
  end;
  AResponseInfo.ContentType := 'application/json';
  // echo a known body that also proves headers arrived (UA + forwarded headers)
  AResponseInfo.ContentText :=
    Format('{"ok":true,"path":"%s","ua":"%s","ref":"%s","conn":"%s","enc":"%s"}',
      [ARequestInfo.Document, ARequestInfo.UserAgent,
       ARequestInfo.RawHeaders.Values['Referer'],
       ARequestInfo.RawHeaders.Values['Connection'],
       ARequestInfo.RawHeaders.Values['Accept-Encoding']]);
end;

procedure TSourceHttpTests.Setup;
var
  Srv: TIdHTTPServer;
begin
  Srv := TIdHTTPServer.Create(nil);
  Srv.DefaultPort := 0; // let the OS pick a free port
  Srv.OnCommandGet := DoGet;
  Srv.Active := True;
  FPort := Srv.Bindings[0].Port;
  FServer := Srv;
end;

procedure TSourceHttpTests.TearDown;
begin
  if FServer <> nil then
  begin
    TIdHTTPServer(FServer).Active := False;
    FServer.Free;
    FServer := nil;
  end;
end;

procedure TSourceHttpTests.HttpGetString_FetchesViaIndy;
var
  Body: string;
begin
  Body := HttpGetString(Format('http://127.0.0.1:%d/hello', [FPort]));
  Assert.IsTrue(Body.Contains('"ok":true'), 'got the server body');
  Assert.IsTrue(Body.Contains('/hello'), 'correct path reached the server');
end;

procedure TSourceHttpTests.HttpGetString_FollowsToBodyForJson;
var
  Body: string;
begin
  // the browser User-Agent must be sent (some panels require it)
  Body := HttpGetString(Format('http://127.0.0.1:%d/player_api.php', [FPort]));
  Assert.IsTrue(Body.Contains('Mozilla/5.0'), 'a browser User-Agent is sent');
end;

procedure TSourceHttpTests.CloudflareChallenge_RaisesProviderBlocked;
begin
  Assert.WillRaise(
    procedure
    begin
      HttpGetString(Format('http://127.0.0.1:%d/cf', [FPort]));
    end,
    EProviderBlocked, 'a Cloudflare challenge page must surface as EProviderBlocked');
end;

procedure TSourceHttpTests.DecodeBytes_HonoursUtf8Bom;
var
  B: TBytes;
begin
  B := [$EF, $BB, $BF, Ord('h'), Ord('i')]; // UTF-8 BOM + "hi"
  Assert.AreEqual('hi', DecodeBytes(B));
end;

procedure TSourceHttpTests.DecodeBytes_AcceptsPlainUtf8;
var
  B: TBytes;
begin
  B := [$C3, $A9]; // U+00E9 'é' encoded as UTF-8, no BOM
  Assert.AreEqual(#$00E9, DecodeBytes(B));
end;

procedure TSourceHttpTests.DecodeBytes_FallsBackToCp1251;
var
  B: TBytes;
begin
  B := [$C0]; // invalid as standalone UTF-8; in Windows-1251 this is 'А' (U+0410)
  Assert.AreEqual(#$0410, DecodeBytes(B), 'non-UTF-8 bytes decode as CP1251');
end;

procedure TSourceHttpTests.DecodeBytes_KeepsEmoji;
var
  B: TBytes;
begin
  // ⚽ U+26BD encodes as UTF-8 E2 9A BD — the ingest READ path must keep it intact
  // (confirms chars arrive correctly via the API; any loss is downstream/storage).
  B := [Ord('A'), $E2, $9A, $BD, Ord('B')];
  Assert.AreEqual('A' + #$26BD + 'B', DecodeBytes(B));
end;

procedure TSourceHttpTests.ForwardsUserAgentAndReferer;
var
  Body: string;
begin
  Body := HttpGetString(Format('http://127.0.0.1:%d/x', [FPort]),
    'VLC/3.0.20 LibVLC/3.0.20', 15000, 'http://provider.example/c/');
  Assert.IsTrue(Body.Contains('"ua":"VLC/3.0.20 LibVLC/3.0.20"'), 'per-provider UA is forwarded');
  Assert.IsTrue(Body.Contains('"ref":"http://provider.example/c/"'), 'Referer is forwarded');
end;

procedure TSourceHttpTests.SendsConnectionCloseAndIdentityEncoding;
var
  Body: string;
begin
  Body := HttpGetString(Format('http://127.0.0.1:%d/x', [FPort]));
  Assert.IsTrue(Body.Contains('"conn":"close"'), 'portal calls send Connection: close');
  Assert.IsTrue(Body.Contains('"enc":"identity"'), 'no gzip — Accept-Encoding identity');
end;

procedure TSourceHttpTests.RetriesOn503ThenSucceeds;
var
  Body: string;
begin
  FFlakyHits := 0;
  // first response is 503; the client backs off once and the retry gets 200
  Body := HttpGetString(Format('http://127.0.0.1:%d/flaky', [FPort]));
  Assert.IsTrue(Body.Contains('"ok":true'), 'a 503 is retried and ultimately succeeds');
  Assert.IsTrue(FFlakyHits >= 2, 'the request was actually retried');
end;

initialization
  TDUnitX.RegisterTestFixture(TSourceHttpTests);

end.
