unit Test.M3U;

{ DUnitX tests for the M3U / M3U_plus parser. ParseContent is pure (text in,
  snapshot out) so it is the easiest core unit to cover. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for the M3U / M3U_plus parser.</summary>
  [TestFixture]
  TM3UTests = class
  public
    /// <summary>M3U_plus attributes (tvg-id, logo, group-title) are parsed.</summary>
    [Test] procedure ParsesM3UPlusAttributes;
    /// <summary>A plain M3U without attributes is parsed.</summary>
    [Test] procedure ParsesPlainM3U;
    /// <summary>Directives between #EXTINF and the URL don't break pairing.</summary>
    [Test] procedure IgnoresUnknownDirectivesBetweenExtinfAndUrl;
    /// <summary>The header's url-tvg becomes the EPG URL.</summary>
    [Test] procedure ReadsUrlTvgFromHeader;
    /// <summary>The same URL yields the same upstream id.</summary>
    [Test] procedure DerivesStableIdFromUrl;
    /// <summary>Path-style credentials don't change the upstream id.</summary>
    [Test] procedure IdSurvivesCredentialSwapPathStyle;
    /// <summary>Query-style credentials don't change the upstream id.</summary>
    [Test] procedure IdSurvivesCredentialSwapQueryStyle;
    /// <summary>Distinct streams keep distinct ids after blanking credentials.</summary>
    [Test] procedure IdStaysDistinctPerStreamAcrossSwap;
    /// <summary>Junk lines are skipped; valid entries survive.</summary>
    [Test] procedure TolerantParserSkipsJunkAndKeepsGoodEntries;
    /// <summary>An #EXTINF without a URL line is dropped.</summary>
    [Test] procedure DropsExtinfWithoutUrlLine;
    /// <summary>The URL path decides the content type, then whole-word group names.</summary>
    [Test] procedure GuessesContentTypeFromUrlThenWholeWords;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Catalog,
  IPTV.Source.M3U;

function Parse(const AContent: string): TSourceSnapshot;
var
  lReader: TM3UReader;
begin
  lReader := TM3UReader.Create;
  try
    Result := TSourceSnapshot.Create(1);
    lReader.ParseContent(AContent, Result);
  finally
    FreeAndNil(lReader);
  end;
end;

function ParseWithCreds(const AContent, AUser, APass: string): TSourceSnapshot;
var
  lReader: TM3UReader;
begin
  lReader := TM3UReader.Create;
  try
    Result := TSourceSnapshot.Create(1);
    lReader.ParseContent(AContent, Result, AUser, APass);
  finally
    FreeAndNil(lReader);
  end;
end;

procedure TM3UTests.ParsesM3UPlusAttributes;
var
  lSnapshot: TSourceSnapshot;
begin
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1 tvg-id="nl1" tvg-name="NPO 1 HD" tvg-logo="http://x/logo.png" ' +
    'group-title="NL | Publiek",NPO 1'#10 +
    'http://provider/live/u/p/101.ts'#10);
  try
    Assert.AreEqual<Integer>(1, lSnapshot.Streams.Count);
    Assert.AreEqual('nl1', lSnapshot.Streams[0].TvgId);
    Assert.AreEqual('NPO 1', lSnapshot.Streams[0].Name);
    Assert.AreEqual('NL | Publiek', lSnapshot.Streams[0].GroupTitle);
    Assert.AreEqual('http://x/logo.png', lSnapshot.Streams[0].Logo);
    Assert.AreEqual('http://provider/live/u/p/101.ts', lSnapshot.Streams[0].UpstreamUrl);
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.ParsesPlainM3U;
var
  lSnapshot: TSourceSnapshot;
begin
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Radio 538'#10 +
    'http://provider/radio.mp3'#10);
  try
    Assert.AreEqual<Integer>(1, lSnapshot.Streams.Count);
    Assert.AreEqual('Radio 538', lSnapshot.Streams[0].Name);
    Assert.AreEqual('', lSnapshot.Streams[0].TvgId);
    Assert.AreEqual('http://provider/radio.mp3', lSnapshot.Streams[0].UpstreamUrl);
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.IgnoresUnknownDirectivesBetweenExtinfAndUrl;
var
  lSnapshot: TSourceSnapshot;
begin
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Test'#10 +
    '#EXTGRP:News'#10 +
    '#EXTVLCOPT:http-user-agent=foo'#10 +
    'http://provider/test.ts'#10);
  try
    Assert.AreEqual<Integer>(1, lSnapshot.Streams.Count);
    Assert.AreEqual('http://provider/test.ts', lSnapshot.Streams[0].UpstreamUrl,
      'directives between EXTINF and URL must not break pairing');
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.ReadsUrlTvgFromHeader;
var
  lSnapshot: TSourceSnapshot;
begin
  lSnapshot := Parse(
    '#EXTM3U url-tvg="http://provider/epg.xml.gz"'#10 +
    '#EXTINF:-1,Ch'#10 +
    'http://provider/ch.ts'#10);
  try
    Assert.AreEqual('http://provider/epg.xml.gz', lSnapshot.EpgUrl);
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.DerivesStableIdFromUrl;
var
  lFirst: TSourceSnapshot;
  lSecond: TSourceSnapshot;
begin
  lFirst := nil;
  lSecond := nil;
  try
    lFirst := Parse('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/same.ts'#10);
    lSecond := Parse('#EXTM3U'#10'#EXTINF:-1,Y'#10'http://p/same.ts'#10);
    // same URL => same upstream id => stable across refreshes / renames
    Assert.AreEqual(lFirst.Streams[0].UpstreamId, lSecond.Streams[0].UpstreamId);
  finally
    FreeAndNil(lFirst);
    FreeAndNil(lSecond);
  end;
end;

procedure TM3UTests.IdSurvivesCredentialSwapPathStyle;
var
  lFirst: TSourceSnapshot;
  lSecond: TSourceSnapshot;
begin
  // same provider, NEW subscription: the Xtream-style M3U embeds creds as path
  // segments (…/live/USER/PASS/ID.ts). The id must stay constant so the curated
  // layout survives the swap (only username/password changed; stream id 101 same).
  lFirst := nil;
  lSecond := nil;
  try
    lFirst := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/live/olduser/oldpass/101.ts'#10,
      'olduser', 'oldpass');
    lSecond := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10'http://p/live/newuser/newpass/101.ts'#10,
      'newuser', 'newpass');
    Assert.AreEqual(lFirst.Streams[0].UpstreamId, lSecond.Streams[0].UpstreamId,
      'credential swap must not change the stream id (path-style)');
  finally
    FreeAndNil(lFirst);
    FreeAndNil(lSecond);
  end;
end;

procedure TM3UTests.IdSurvivesCredentialSwapQueryStyle;
var
  lFirst: TSourceSnapshot;
  lSecond: TSourceSnapshot;
begin
  // query-style creds (…?username=…&password=…&stream=12345)
  lFirst := nil;
  lSecond := nil;
  try
    lFirst := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10 +
      'http://p/stream?username=olduser&password=oldpass&id=12345'#10, 'olduser', 'oldpass');
    lSecond := ParseWithCreds('#EXTM3U'#10'#EXTINF:-1,X'#10 +
      'http://p/stream?username=newuser&password=newpass&id=12345'#10, 'newuser', 'newpass');
    Assert.AreEqual(lFirst.Streams[0].UpstreamId, lSecond.Streams[0].UpstreamId,
      'credential swap must not change the stream id (query-style)');
  finally
    FreeAndNil(lFirst);
    FreeAndNil(lSecond);
  end;
end;

procedure TM3UTests.IdStaysDistinctPerStreamAcrossSwap;
var
  lSnapshot: TSourceSnapshot;
begin
  // blanking creds must NOT collapse two different streams into one id (the
  // discriminating stream id is what's left after the creds are removed)
  lSnapshot := ParseWithCreds('#EXTM3U'#10 +
    '#EXTINF:-1,One'#10'http://p/live/u/p/101.ts'#10 +
    '#EXTINF:-1,Two'#10'http://p/live/u/p/102.ts'#10, 'u', 'p');
  try
    Assert.AreEqual<Integer>(2, lSnapshot.Streams.Count);
    Assert.AreNotEqual(lSnapshot.Streams[0].UpstreamId, lSnapshot.Streams[1].UpstreamId,
      'distinct streams must keep distinct ids after creds are blanked');
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.TolerantParserSkipsJunkAndKeepsGoodEntries;
var
  lSnapshot: TSourceSnapshot;
begin
  // a provider dumps a stray non-standard line between valid entries — the parser
  // must log-and-skip, not abort the whole playlist (#16)
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Good One'#10 +
    'http://provider/one.ts'#10 +
    'this is not a valid line at all'#10 +
    '#EXTINF:-1,Good Two'#10 +
    'http://provider/two.ts'#10);
  try
    Assert.AreEqual<Integer>(2, lSnapshot.Streams.Count, 'both valid channels survive the junk line');
    Assert.AreEqual('Good One', lSnapshot.Streams[0].Name);
    Assert.AreEqual('Good Two', lSnapshot.Streams[1].Name);
  finally
    FreeAndNil(lSnapshot);
  end;
end;

procedure TM3UTests.DropsExtinfWithoutUrlLine;
var
  lSnapshot: TSourceSnapshot;
begin
  // a #EXTINF with no following URL line (another #EXTINF comes next, or EOF) must
  // NOT persist as a ghost stream with an empty URL/id (those collide on the merge
  // key and serve a dead row).
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1,Ghost No Url'#10 +     // no URL — next line is another #EXTINF
    '#EXTINF:-1,Real Channel'#10 +
    'http://provider/real.ts'#10 +
    '#EXTINF:-1,Trailing Ghost'#10);   // no URL — end of file
  try
    Assert.AreEqual<Integer>(1, lSnapshot.Streams.Count, 'only the channel with a URL survives');
    Assert.AreEqual('Real Channel', lSnapshot.Streams[0].Name);
    Assert.AreEqual('http://provider/real.ts', lSnapshot.Streams[0].UpstreamUrl);
  finally
    FreeAndNil(lSnapshot);
  end;
end;

// the /live/ /movie/ /series/ URL path wins; group names only count as whole words
procedure TM3UTests.GuessesContentTypeFromUrlThenWholeWords;
var
  lSnapshot: TSourceSnapshot;

  function TypeOf(const AName: string): TContentType;
  var
    lStream: TStreamItem;
  begin
    for lStream in lSnapshot.Streams do
      if lStream.Name = AName then
        Exit(lStream.ContentType);
    raise Exception.Create('missing ' + AName);
  end;

begin
  lSnapshot := Parse(
    '#EXTM3U'#10 +
    '#EXTINF:-1 group-title="NL| FILM",Film1 Action'#10 + 'http://p:80/live/u/p/1.ts'#10 +
    '#EXTINF:-1 group-title="VODAFONE SPORT",Sport X'#10 + 'http://p:80/x/2.ts'#10 +
    '#EXTINF:-1 group-title="Films 2024",Some Movie'#10 + 'http://p:80/x/3.mp4'#10 +
    '#EXTINF:-1 group-title="NL",Other Movie'#10 + 'http://p:80/movie/u/p/4.mkv'#10 +
    '#EXTINF:-1 group-title="Radio NL",Radio 1'#10 + 'http://p:80/live/u/p/5.ts'#10 +
    '#EXTINF:-1 group-title="Netflix Series",Ep 1'#10 + 'http://p:80/x/6.mp4'#10);
  try
    Assert.AreEqual(Ord(ctLive), Ord(TypeOf('Film1 Action')), 'live URL beats "FILM" group');
    Assert.AreEqual(Ord(ctLive), Ord(TypeOf('Sport X')), '"VODAFONE" is not "vod"');
    Assert.AreEqual(Ord(ctMovie), Ord(TypeOf('Some Movie')));
    Assert.AreEqual(Ord(ctMovie), Ord(TypeOf('Other Movie')), '/movie/ URL');
    Assert.AreEqual(Ord(ctRadio), Ord(TypeOf('Radio 1')));
    Assert.AreEqual(Ord(ctSeries), Ord(TypeOf('Ep 1')));
  finally
    FreeAndNil(lSnapshot);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TM3UTests);

end.
