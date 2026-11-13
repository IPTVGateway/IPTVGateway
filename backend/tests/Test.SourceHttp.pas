unit Test.SourceHttp;

{ Tests the shared HTTP fetch (IPTV.Source.Http). The http path goes through Indy
  (lenient — the whole reason for the hybrid), which we verify end-to-end against
  a throwaway local TIdHTTPServer. No external network. }

interface

uses
  // third-party
  DUnitX.TestFramework,
  IdCustomHTTPServer,
  IdContext;

type
  /// <summary>Tests for the shared HTTP fetch against a local Indy server.</summary>
  [TestFixture]
  TSourceHttpTests = class
  private
    FServer: TObject; // TIdHTTPServer (kept opaque in the interface)
    FPort: Integer;
    FFlakyHits: Integer; // counts hits on /flaky to exercise 503 backoff
    /// <summary>Local server handler: /cf challenge, /flaky 503, else a JSON echo.</summary>
    procedure DoGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  public
    /// <summary>Starts the local HTTP server on a free port.</summary>
    [Setup] procedure Setup;
    /// <summary>Stops and frees the local HTTP server.</summary>
    [TearDown] procedure TearDown;
    /// <summary>A plain GET returns the server body.</summary>
    [Test] procedure HttpGetString_FetchesViaIndy;
    /// <summary>A browser User-Agent is sent.</summary>
    [Test] procedure HttpGetString_FollowsToBodyForJson;
    /// <summary>A Cloudflare challenge raises EProviderBlocked.</summary>
    [Test] procedure CloudflareChallenge_RaisesProviderBlocked;
    /// <summary>A UTF-8 BOM is honoured and stripped.</summary>
    [Test] procedure DecodeBytes_HonoursUtf8Bom;
    /// <summary>Plain UTF-8 without BOM decodes.</summary>
    [Test] procedure DecodeBytes_AcceptsPlainUtf8;
    /// <summary>Invalid UTF-8 falls back to CP1251.</summary>
    [Test] procedure DecodeBytes_FallsBackToCp1251;
    /// <summary>Emoji survive decoding.</summary>
    [Test] procedure DecodeBytes_KeepsEmoji;
    /// <summary>Per-provider User-Agent and Referer are forwarded.</summary>
    [Test] procedure ForwardsUserAgentAndReferer;
    /// <summary>Requests send Connection: close and identity encoding.</summary>
    [Test] procedure SendsConnectionCloseAndIdentityEncoding;
    /// <summary>A 503 is retried and then succeeds.</summary>
    [Test] procedure RetriesOn503ThenSucceeds;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  // third-party
  IdHTTPServer,
  // own units
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
  lServer: TIdHTTPServer;
begin
  lServer := TIdHTTPServer.Create(nil);
  lServer.DefaultPort := 0; // let the OS pick a free port
  lServer.OnCommandGet := DoGet;
  lServer.Active := True;
  FPort := lServer.Bindings[0].Port;
  FServer := lServer;
end;

procedure TSourceHttpTests.TearDown;
begin
  if FServer <> nil then
  begin
    TIdHTTPServer(FServer).Active := False;
    FreeAndNil(FServer);
  end;
end;

procedure TSourceHttpTests.HttpGetString_FetchesViaIndy;
var
  lBody: string;
begin
  lBody := HttpGetString(Format('http://127.0.0.1:%d/hello', [FPort]));
  Assert.IsTrue(lBody.Contains('"ok":true'), 'got the server body');
  Assert.IsTrue(lBody.Contains('/hello'), 'correct path reached the server');
end;

procedure TSourceHttpTests.HttpGetString_FollowsToBodyForJson;
var
  lBody: string;
begin
  // the browser User-Agent must be sent (some panels require it)
  lBody := HttpGetString(Format('http://127.0.0.1:%d/player_api.php', [FPort]));
  Assert.IsTrue(lBody.Contains('Mozilla/5.0'), 'a browser User-Agent is sent');
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
  lBytes: TBytes;
begin
  lBytes := [$EF, $BB, $BF, Ord('h'), Ord('i')]; // UTF-8 BOM + "hi"
  Assert.AreEqual('hi', DecodeBytes(lBytes));
end;

procedure TSourceHttpTests.DecodeBytes_AcceptsPlainUtf8;
var
  lBytes: TBytes;
begin
  lBytes := [$C3, $A9]; // U+00E9 'é' encoded as UTF-8, no BOM
  Assert.AreEqual(#$00E9, DecodeBytes(lBytes));
end;

procedure TSourceHttpTests.DecodeBytes_FallsBackToCp1251;
var
  lBytes: TBytes;
begin
  lBytes := [$C0]; // invalid as standalone UTF-8; in Windows-1251 this is 'А' (U+0410)
  Assert.AreEqual(#$0410, DecodeBytes(lBytes), 'non-UTF-8 bytes decode as CP1251');
end;

procedure TSourceHttpTests.DecodeBytes_KeepsEmoji;
var
  lBytes: TBytes;
begin
  // ⚽ U+26BD encodes as UTF-8 E2 9A BD — the ingest READ path must keep it intact
  // (confirms chars arrive correctly via the API; any loss is downstream/storage).
  lBytes := [Ord('A'), $E2, $9A, $BD, Ord('B')];
  Assert.AreEqual('A' + #$26BD + 'B', DecodeBytes(lBytes));
end;

procedure TSourceHttpTests.ForwardsUserAgentAndReferer;
var
  lBody: string;
begin
  lBody := HttpGetString(Format('http://127.0.0.1:%d/x', [FPort]),
    'VLC/3.0.20 LibVLC/3.0.20', 15000, 'http://provider.example/c/');
  Assert.IsTrue(lBody.Contains('"ua":"VLC/3.0.20 LibVLC/3.0.20"'), 'per-provider UA is forwarded');
  Assert.IsTrue(lBody.Contains('"ref":"http://provider.example/c/"'), 'Referer is forwarded');
end;

procedure TSourceHttpTests.SendsConnectionCloseAndIdentityEncoding;
var
  lBody: string;
begin
  lBody := HttpGetString(Format('http://127.0.0.1:%d/x', [FPort]));
  Assert.IsTrue(lBody.Contains('"conn":"close"'), 'portal calls send Connection: close');
  Assert.IsTrue(lBody.Contains('"enc":"identity"'), 'no gzip — Accept-Encoding identity');
end;

procedure TSourceHttpTests.RetriesOn503ThenSucceeds;
var
  lBody: string;
begin
  FFlakyHits := 0;
  // first response is 503; the client backs off once and the retry gets 200
  lBody := HttpGetString(Format('http://127.0.0.1:%d/flaky', [FPort]));
  Assert.IsTrue(lBody.Contains('"ok":true'), 'a 503 is retried and ultimately succeeds');
  Assert.IsTrue(FFlakyHits >= 2, 'the request was actually retried');
end;

initialization
  TDUnitX.RegisterTestFixture(TSourceHttpTests);

end.
