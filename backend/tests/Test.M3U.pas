unit Test.M3U;

{ DUnitX tests for the M3U / M3U_plus parser. ParseContent is pure (text in,
  snapshot out) so it is the easiest core unit to cover. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TM3UTests = class
  public
    [Test] procedure ParsesM3UPlusAttributes;
    [Test] procedure ParsesPlainM3U;
    [Test] procedure IgnoresUnknownDirectivesBetweenExtinfAndUrl;
    [Test] procedure ReadsUrlTvgFromHeader;
    [Test] procedure DerivesStableIdFromUrl;
    [Test] procedure IdSurvivesCredentialSwapPathStyle;
    [Test] procedure IdSurvivesCredentialSwapQueryStyle;
    [Test] procedure IdStaysDistinctPerStreamAcrossSwap;
    [Test] procedure TolerantParserSkipsJunkAndKeepsGoodEntries;
    [Test] procedure DropsExtinfWithoutUrlLine;
  end;

implementation

uses
  IPTV.Model.Catalog, IPTV.Source.M3U;

function Parse(const AContent: string): TSourceSnapshot;
var
  Reader: TM3UReader;
begin
  Reader := TM3UReader.Create;
  try
    Result := TSourceSnapshot.Create(1);
    Reader.ParseContent(AContent, Result);
  finally
    Reader.Free;
  end;
end;

function ParseWithCreds(const AContent, AUser, APass: string): TSourceSnapshot;
var
  Reader: TM3UReader;
begin
  Reader := TM3UReader.Create;
  try
    Result := TSourceSnapshot.Create(1);
    Reader.ParseContent(AContent, Result, AUser, APass);
  finally
    Reader.Free;
  end;
end;

procedure TM3UTests.ParsesM3UPlusAttributes;
var
  Snap: TSourceSnapshot;
begin
  Snap := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1 tvg-id="nl1" tvg-name="NPO 1 HD" tvg-logo="http://x/logo.png" group-title="NL | Publiek",NPO 1'#10 +
    'http://provider/live/u/p/101.ts'#10);
  try
    Assert.AreEqual<Integer>(1, Snap.Streams.Count);
    Assert.AreEqual('nl1', Snap.Streams[0].TvgId);
    Assert.AreEqual('NPO 1', Snap.Streams[0].Name);
    Assert.AreEqual('NL | Publiek', Snap.Streams[0].GroupTitle);
    Assert.AreEqual('http://x/logo.png', Snap.Streams[0].Logo);
    Assert.AreEqual('http://provider/live/u/p/101.ts', Snap.Streams[0].UpstreamUrl);
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.ParsesPlainM3U;
var
  Snap: TSourceSnapshot;
begin
  Snap := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Radio 538'#10 +
    'http://provider/radio.mp3'#10);
  try
    Assert.AreEqual<Integer>(1, Snap.Streams.Count);
    Assert.AreEqual('Radio 538', Snap.Streams[0].Name);
    Assert.AreEqual('', Snap.Streams[0].TvgId);
    Assert.AreEqual('http://provider/radio.mp3', Snap.Streams[0].UpstreamUrl);
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.IgnoresUnknownDirectivesBetweenExtinfAndUrl;
var
  Snap: TSourceSnapshot;
begin
  Snap := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Test'#10 +
    '#EXTGRP:News'#10 +
    '#EXTVLCOPT:http-user-agent=foo'#10 +
    'http://provider/test.ts'#10);
  try
    Assert.AreEqual<Integer>(1, Snap.Streams.Count);
    Assert.AreEqual('http://provider/test.ts', Snap.Streams[0].UpstreamUrl,
      'directives between EXTINF and URL must not break pairing');
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.ReadsUrlTvgFromHeader;
var
  Snap: TSourceSnapshot;
begin
  Snap := Parse(
    '#EXTM3U url-tvg="http://provider/epg.xml.gz"'#10 +
    '#EXTINF:-1,Ch'#10 +
    'http://provider/ch.ts'#10);
  try
    Assert.AreEqual('http://provider/epg.xml.gz', Snap.EpgUrl);
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.DerivesStableIdFromUrl;
var
  A, B: TSourceSnapshot;
begin
  A := Parse('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/same.ts'#10);
  B := Parse('#EXTM3U'#10'#EXTINF:-1,Y'#10'http://p/same.ts'#10);
  try
    // same URL => same upstream id => stable across refreshes / renames
    Assert.AreEqual(A.Streams[0].UpstreamId, B.Streams[0].UpstreamId);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TM3UTests.IdSurvivesCredentialSwapPathStyle;
var
  A, B: TSourceSnapshot;
begin
  // same provider, NEW subscription: the Xtream-style M3U embeds creds as path
  // segments (…/live/USER/PASS/ID.ts). The id must stay constant so the curated
  // layout survives the swap (only username/password changed; stream id 101 same).
  A := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/live/olduser/oldpass/101.ts'#10,
    'olduser', 'oldpass');
  B := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/live/newuser/newpass/101.ts'#10,
    'newuser', 'newpass');
  try
    Assert.AreEqual(A.Streams[0].UpstreamId, B.Streams[0].UpstreamId,
      'credential swap must not change the stream id (path-style)');
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TM3UTests.IdSurvivesCredentialSwapQueryStyle;
var
  A, B: TSourceSnapshot;
begin
  // query-style creds (…?username=…&password=…&stream=12345)
  A := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10 +
    'http://p/stream?username=olduser&password=oldpass&id=12345'#10, 'olduser', 'oldpass');
  B := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10 +
    'http://p/stream?username=newuser&password=newpass&id=12345'#10, 'newuser', 'newpass');
  try
    Assert.AreEqual(A.Streams[0].UpstreamId, B.Streams[0].UpstreamId,
      'credential swap must not change the stream id (query-style)');
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TM3UTests.IdStaysDistinctPerStreamAcrossSwap;
var
  Snap: TSourceSnapshot;
begin
  // blanking creds must NOT collapse two different streams into one id (the
  // discriminating stream id is what's left after the creds are removed)
  Snap := ParseWithCreds('#EXTM3U'#10 +
    '#EXTINF:-1,One'#10'http://p/live/u/p/101.ts'#10 +
    '#EXTINF:-1,Two'#10'http://p/live/u/p/102.ts'#10, 'u', 'p');
  try
    Assert.AreEqual<Integer>(2, Snap.Streams.Count);
    Assert.AreNotEqual(Snap.Streams[0].UpstreamId, Snap.Streams[1].UpstreamId,
      'distinct streams must keep distinct ids after creds are blanked');
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.TolerantParserSkipsJunkAndKeepsGoodEntries;
var
  Snap: TSourceSnapshot;
begin
  // a provider dumps a stray non-standard line between valid entries — the parser
  // must log-and-skip, not abort the whole playlist (#16)
  Snap := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Good One'#10 +
    'http://provider/one.ts'#10 +
    'this is not a valid line at all'#10 +
    '#EXTINF:-1,Good Two'#10 +
    'http://provider/two.ts'#10);
  try
    Assert.AreEqual<Integer>(2, Snap.Streams.Count, 'both valid channels survive the junk line');
    Assert.AreEqual('Good One', Snap.Streams[0].Name);
    Assert.AreEqual('Good Two', Snap.Streams[1].Name);
  finally
    Snap.Free;
  end;
end;

procedure TM3UTests.DropsExtinfWithoutUrlLine;
var
  Snap: TSourceSnapshot;
begin
  // a #EXTINF with no following URL line (another #EXTINF comes next, or EOF) must
  // NOT persist as a ghost stream with an empty URL/id (those collide on the merge
  // key and serve a dead row).
  Snap := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Ghost No Url'#10 +     // no URL — next line is another #EXTINF
    '#EXTINF:-1,Real Channel'#10 +
    'http://provider/real.ts'#10 +
    '#EXTINF:-1,Trailing Ghost'#10);   // no URL — end of file
  try
    Assert.AreEqual<Integer>(1, Snap.Streams.Count, 'only the channel with a URL survives');
    Assert.AreEqual('Real Channel', Snap.Streams[0].Name);
    Assert.AreEqual('http://provider/real.ts', Snap.Streams[0].UpstreamUrl);
  finally
    Snap.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TM3UTests);

end.
