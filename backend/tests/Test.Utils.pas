unit Test.Utils;

{ Tests for IPTV.Core.Utils: content-type CSV and ISO-8601 UTC round-trips. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for IPTV.Core.Utils and related helpers.</summary>
  [TestFixture]
  TUtilsTests = class
  public
    /// <summary>Content-type sets round-trip through the CSV form.</summary>
    [Test] procedure ContentTypesRoundtrip;
    /// <summary>Blank CSV entries are ignored.</summary>
    [Test] procedure ContentTypesParseIgnoresBlanks;
    /// <summary>ISO-8601 UTC dates round-trip.</summary>
    [Test] procedure IsoDateRoundtrip;
    /// <summary>An empty ISO date is 0 and vice versa.</summary>
    [Test] procedure EmptyDateIsZero;
    /// <summary>A prefix token clears the common separator shapes.</summary>
    [Test] procedure StripPrefix_HandlesPipeAndSpaceVariants;
    /// <summary>Unicode vertical bars count as separators.</summary>
    [Test] procedure StripPrefix_HandlesUnicodeVerticalBars;
    /// <summary>A prefix only strips at a word boundary.</summary>
    [Test] procedure StripPrefix_RequiresWordBoundary;
    /// <summary>Prefix stripping is case-insensitive and trims.</summary>
    [Test] procedure StripPrefix_IsCaseInsensitiveAndTrims;
    /// <summary>Chained prefixes are all stripped.</summary>
    [Test] procedure StripPrefix_StripsMultiplePrefixes;
    /// <summary>Without a match the name is only trimmed.</summary>
    [Test] procedure StripPrefix_NoTokensOrNoMatchLeavesNameTrimmed;
    /// <summary>A trailing quality token is detected and stripped.</summary>
    [Test] procedure Quality_DetectsAndStripsTrailingToken;
    /// <summary>Quality variants of one channel share the base key.</summary>
    [Test] procedure Quality_VariantsShareBaseKey;
    /// <summary>Plus tiers (4K+) are distinct qualities.</summary>
    [Test] procedure Quality_PlusTiersAreDistinct;
    /// <summary>Without a quality word the name is the base key.</summary>
    [Test] procedure Quality_NoneLeavesNameAsBase;
    /// <summary>Quality synonyms map to the canonical form.</summary>
    [Test] procedure Quality_CanonicalMapsSynonyms;
    /// <summary>Small-caps RAW is a quality.</summary>
    [Test] procedure Quality_SmallCapsRawIsAQuality;
    /// <summary>The head key ignores tags after the quality.</summary>
    [Test] procedure Quality_HeadKeyIgnoresTagsAfterQuality;
    /// <summary>Suffix tokens remove trailing tags.</summary>
    [Test] procedure StripSuffix_RemovesTrailingTags;
    /// <summary>Suffixes strip at word boundaries only and never empty the name.</summary>
    [Test] procedure StripSuffix_RequiresWordBoundaryAndKeepsName;
    /// <summary>CleanChannelName applies prefixes and suffixes.</summary>
    [Test] procedure CleanChannelName_PrefixAndSuffix;
    /// <summary>Timeshift start parses the wire and other forms.</summary>
    [Test] procedure Timeshift_ParsesWireAndOtherForms;
    /// <summary>The portal clock offset derives from server_info.</summary>
    [Test] procedure Timeshift_PortalOffsetFromServerInfo;
    /// <summary>The timeshift URL shifts the start to the portal clock.</summary>
    [Test] procedure Timeshift_UrlShiftsStartToPortalClock;
    /// <summary>Xtream Base64 output has no line breaks.</summary>
    [Test] procedure XtreamBase64_IsOneLine;
    /// <summary>EPG name/id keys match provider and guide names.</summary>
    [Test] procedure EpgKeys_MatchProviderAndGuideNames;
    /// <summary>EpgIdKey strips only country codes.</summary>
    [Test] procedure EpgIdKey_StripsOnlyCountryCodes;
    /// <summary>Missing stop times use the next start.</summary>
    [Test] procedure FillMissingStops_UsesNextStart;
    /// <summary>XMLTV attributes are read in both quote styles.</summary>
    [Test] procedure XmltvAttr_BothQuoteStyles;
    /// <summary>FirstEpgUrl takes the first URL of a list.</summary>
    [Test] procedure FirstEpgUrl_TakesFirstOfList;
    /// <summary>publicBaseUrl is normalised and validated.</summary>
    [Test] procedure PublicBaseUrl_Normalised;
    /// <summary>Non-UTF-8 bytes decode as Latin-1 or CP1251.</summary>
    [Test] procedure DecodeBytes_Latin1AndCyrillic;
    /// <summary>The URL extension is swapped in the path only.</summary>
    [Test] procedure SwapUrlExt_OnlyInPath;
    /// <summary>The client allow-list matches IPs and prefixes.</summary>
    [Test] procedure ClientAllowList_IpsAndPrefixes;
    /// <summary>Password comparison is exact.</summary>
    [Test] procedure SamePassword_ConstantTimeCompare;
    /// <summary>Provider logins in an Xtream URL path: only path-breaking characters are escaped.</summary>
    [Test] procedure UrlPathSafe_EscapesOnlyPathBreakers;
    /// <summary>Failed logins lock an IP out after the limit; other IPs are unaffected.</summary>
    [Test] procedure AuthThrottle_LocksOutAfterTooManyFailures;
    /// <summary>SSDP replies echo the requested search target and skip foreign ones.</summary>
    [Test] procedure Ssdp_RepliesWithTheRequestedSearchTarget;
    /// <summary>Credentials in URLs are masked.</summary>
    [Test] procedure MaskUrlSecrets_HidesCredentials;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.DateUtils,
  System.NetEncoding,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Epg,
  IPTV.Core.Utils,
  IPTV.Source.Epg,
  IPTV.Source.Http,
  IPTV.Output.Builder,
  IPTV.Api.AuthThrottle,
  IPTV.Api.SsdpServer;

procedure TUtilsTests.ContentTypesRoundtrip;
var
  lTypes: TContentTypes;
begin
  lTypes := [ctLive, ctSeries];
  Assert.IsTrue(lTypes = StrToContentTypes(ContentTypesToStr(lTypes)));
  Assert.IsTrue(AllContentTypes = StrToContentTypes(ContentTypesToStr(AllContentTypes)));
end;

procedure TUtilsTests.ContentTypesParseIgnoresBlanks;
begin
  Assert.IsTrue([ctLive, ctRadio] = StrToContentTypes(' live , , radio '));
end;

procedure TUtilsTests.IsoDateRoundtrip;
var
  lDate: TDateTime;
begin
  lDate := EncodeDateTime(2026, 6, 14, 18, 30, 0, 0);
  Assert.AreEqual(lDate, IsoUtcToDateTime(DateTimeToIsoUtc(lDate)), 1.0 / 86400);
end;

procedure TUtilsTests.EmptyDateIsZero;
begin
  Assert.AreEqual<TDateTime>(0, IsoUtcToDateTime(''));
  Assert.AreEqual('', DateTimeToIsoUtc(0));
end;

procedure TUtilsTests.StripPrefix_HandlesPipeAndSpaceVariants;
begin
  // a single token "NL" must clear every common provider prefix shape
  Assert.AreEqual('NPO 1 HD', StripNamePrefixes('NL| NPO 1 HD', ['NL']));
  Assert.AreEqual('NPO 1 HD', StripNamePrefixes('NL | NPO 1 HD', ['NL']));
  Assert.AreEqual('NPO 1 HD', StripNamePrefixes('|NL| NPO 1 HD', ['NL']));
  Assert.AreEqual('NPO 1 HD', StripNamePrefixes('NL - NPO 1 HD', ['NL']));
  Assert.AreEqual('NPO 1 HD', StripNamePrefixes('NL: NPO 1 HD', ['NL']));
end;

procedure TUtilsTests.StripPrefix_HandlesUnicodeVerticalBars;
const
  HB = #$2503; // ┃ heavy vertical bar (U+2503) — what ProviderA actually uses
  LB = #$2502; // │ light vertical bar (U+2502)
  FW = #$FF5C; // ｜ fullwidth vertical line
begin
  // real-world: providers wrap a tag in Unicode bars, NOT the ASCII pipe.
  // "┃F1 TV┃ NPO 1" with token "F1 TV" must strip to "NPO 1"
  Assert.AreEqual('NPO 1', StripNamePrefixes(HB + 'F1 TV' + HB + ' NPO 1', ['F1 TV']));
  Assert.AreEqual('NPO 1', StripNamePrefixes(LB + 'NL' + LB + ' NPO 1', ['NL']));
  Assert.AreEqual('NPO 1', StripNamePrefixes(FW + 'NL' + FW + ' NPO 1', ['NL']));
  // bare heavy-bar prefix, no trailing bar
  Assert.AreEqual('NPO 1', StripNamePrefixes(HB + 'NL' + HB + 'NPO 1', ['NL']));
end;

procedure TUtilsTests.StripPrefix_RequiresWordBoundary;
begin
  // "NL" must NOT eat the start of a real word
  Assert.AreEqual('Netherlands 1', StripNamePrefixes('Netherlands 1', ['NL']));
  Assert.AreEqual('NLD Sport', StripNamePrefixes('NLD Sport', ['NL']));
end;

procedure TUtilsTests.StripPrefix_IsCaseInsensitiveAndTrims;
begin
  Assert.AreEqual('NPO 1', StripNamePrefixes('nl|  NPO 1  ', ['NL']));
  // surrounding separators in the configured token are ignored
  Assert.AreEqual('NPO 1', StripNamePrefixes('NL| NPO 1', ['|NL|']));
end;

procedure TUtilsTests.StripPrefix_StripsMultiplePrefixes;
begin
  // chained prefixes collapse when each token is configured
  Assert.AreEqual('Sport', StripNamePrefixes('NL| UK| Sport', ['NL', 'UK']));
end;

procedure TUtilsTests.StripPrefix_NoTokensOrNoMatchLeavesNameTrimmed;
begin
  Assert.AreEqual('NPO 1', StripNamePrefixes('  NPO 1  ', []));
  Assert.AreEqual('UK| Sport', StripNamePrefixes('UK| Sport', ['NL']));
end;

procedure TUtilsTests.Quality_DetectsAndStripsTrailingToken;
var
  lQuality: string;
begin
  Assert.AreEqual('nl npo 1', QualityMatchKey('NL| NPO 1 HD', lQuality));
  Assert.AreEqual('HD', lQuality);
  Assert.AreEqual('espn 1', QualityMatchKey('ESPN 1 UHD', lQuality));
  Assert.AreEqual('UHD', lQuality);
end;

procedure TUtilsTests.Quality_VariantsShareBaseKey;
var
  lQualityA: string;
  lQualityB: string;
begin
  // the whole point: HD and UHD of one channel key to the same base
  Assert.AreEqual(QualityMatchKey('NL| NPO 1 HD', lQualityA), QualityMatchKey('NL| NPO 1 UHD', lQualityB));
  Assert.AreEqual('HD', lQualityA);
  Assert.AreEqual('UHD', lQualityB);
end;

procedure TUtilsTests.Quality_PlusTiersAreDistinct;
var
  lQuality: string;
begin
  // "4K+" must canonicalise as a tier distinct from "4K"
  Assert.AreEqual('film1 action', QualityMatchKey('Film1 Action 4K+', lQuality));
  Assert.AreEqual('4K+', lQuality);
  Assert.AreEqual('4K', CanonicalQuality('4k'));
  Assert.AreNotEqual('4K', CanonicalQuality('4k+'));
end;

procedure TUtilsTests.Quality_NoneLeavesNameAsBase;
var
  lQuality: string;
begin
  // no quality word → quality empty, base is the (lowercased) name
  Assert.AreEqual('discovery channel', QualityMatchKey('Discovery Channel', lQuality));
  Assert.AreEqual('', lQuality);
  // a quality-looking substring inside a word is NOT a token ("HD" in "HDNET")
  Assert.AreEqual('hdnet', QualityMatchKey('HDNET', lQuality));
  Assert.AreEqual('', lQuality);
end;

procedure TUtilsTests.Quality_CanonicalMapsSynonyms;
begin
  Assert.AreEqual('FHD', CanonicalQuality('FullHD'));
  Assert.AreEqual('UHD', CanonicalQuality('uhd'));
  Assert.AreEqual('', CanonicalQuality('Sports')); // not a quality
end;

const
  RAW_SC = #$0280#$1D00#$1D21;          // small-caps "RAW" as ProviderB writes it
  REC_SUP = #$23FA#$02B3#$1D49#$1D9C;   // record-dot + superscript "rec" (ProviderA)

procedure TUtilsTests.Quality_SmallCapsRawIsAQuality;
var
  lQualityA: string;
  lQualityB: string;
begin
  Assert.AreEqual('RAW', CanonicalQuality(RAW_SC));
  Assert.AreEqual('RAW', CanonicalQuality('raw'));
  // a RAW channel and its 4K+ variant share the base key
  Assert.AreEqual(QualityMatchKey('NL | NPO 1 ' + RAW_SC, lQualityA), QualityMatchKey('NL | NPO 1 4K+', lQualityB));
  Assert.AreEqual('RAW', lQualityA);
  Assert.AreEqual('4K+', lQualityB);
  // decorative letters in the rest of the name are folded too
  Assert.AreEqual('npo 1 rec', QualityMatchKey('NPO 1 HD ' + REC_SUP, lQualityA));
end;

procedure TUtilsTests.Quality_HeadKeyIgnoresTagsAfterQuality;
var
  lQuality: string;
  lHead: string;
begin
  Assert.AreEqual('nl history s', QualityMatchKey('NL | HISTORY ' + RAW_SC + ' (S)', lQuality, lHead));
  Assert.AreEqual('nl history', lHead);
  Assert.AreEqual('RAW', lQuality);
  // nothing after the quality: head = base
  Assert.AreEqual('nl npo 1', QualityMatchKey('NL | NPO 1 4K+', lQuality, lHead));
  Assert.AreEqual('nl npo 1', lHead);
  // no quality: head = base
  QualityMatchKey('Discovery Channel', lQuality, lHead);
  Assert.AreEqual('discovery channel', lHead);
end;

procedure TUtilsTests.StripSuffix_RemovesTrailingTags;
begin
  Assert.AreEqual('HISTORY ' + RAW_SC, StripNameSuffixes('HISTORY ' + RAW_SC + ' (S)', ['(S)']));
  Assert.AreEqual('HISTORY', StripNameSuffixes('HISTORY ' + RAW_SC + ' (S)', ['(S)', 'RAW']));
  // the plain token "rec" also removes the superscript form + its record dot
  Assert.AreEqual('NPO 1 HD', StripNameSuffixes('NPO 1 HD  ' + REC_SUP, ['rec']));
  Assert.AreEqual('NPO 1', StripNameSuffixes('NPO 1 | HD', ['hd']));
end;

procedure TUtilsTests.StripSuffix_RequiresWordBoundaryAndKeepsName;
begin
  Assert.AreEqual('SPORT1HD', StripNameSuffixes('SPORT1HD', ['HD']));
  Assert.AreEqual('NPO 1', StripNameSuffixes('  NPO 1  ', []));
  // never strip a name down to nothing
  Assert.AreEqual('HD', StripNameSuffixes('HD', ['HD']));
end;

procedure TUtilsTests.CleanChannelName_PrefixAndSuffix;
begin
  Assert.AreEqual('DISCOVERY SCIENCE ' + RAW_SC,
    CleanChannelName('NL | DISCOVERY SCIENCE ' + RAW_SC + ' (S)', ['NL |'], ['(S)']));
  Assert.AreEqual('NPO 1 HD', CleanChannelName(#$2503'NL'#$2503' NPO 1 HD ' + REC_SUP, ['NL'], ['rec']));
end;

procedure TUtilsTests.Timeshift_ParsesWireAndOtherForms;
var
  lStart: TDateTime;
begin
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12:20-30', lStart));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), lStart, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12:20-30-15', lStart));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 15, 0), lStart, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12 20:30:00', lStart));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), lStart, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart(
    IntToStr(DateTimeToUnix(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), True)), lStart));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), lStart, 1 / 86400);
  Assert.IsFalse(ParseTimeshiftStart('', lStart));
  Assert.IsFalse(ParseTimeshiftStart('2026-13-40:20-30', lStart), 'invalid date');
  Assert.IsFalse(ParseTimeshiftStart('yesterday', lStart));
  Assert.AreEqual('2026-11-12:20-30', FormatTimeshiftStart(EncodeDateTime(2026, 11, 12, 20, 30, 59, 0)));
end;

procedure TUtilsTests.Timeshift_PortalOffsetFromServerInfo;
var
  lOffset: Integer;
  lUnix: Int64;
begin
  lUnix := DateTimeToUnix(EncodeDateTime(2026, 11, 13, 13, 0, 0, 0), True);
  // CET portal: local 14:00:02 while UTC is 13:00 -> +60 (rounded to 15 min)
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 14:00:02', lUnix, lOffset));
  Assert.AreEqual(60, lOffset);
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 08:00:00', lUnix, lOffset));
  Assert.AreEqual(-300, lOffset, 'US east');
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 13:00:00', lUnix, lOffset));
  Assert.AreEqual(0, lOffset);
  Assert.IsFalse(XtreamTzOffsetMin('', lUnix, lOffset), 'no time_now');
  Assert.IsFalse(XtreamTzOffsetMin('2026-11-13 14:00:00', 0, lOffset), 'no timestamp_now');
  Assert.IsFalse(XtreamTzOffsetMin('2026-11-20 14:00:00', lUnix, lOffset), 'a week off is nonsense');
end;

procedure TUtilsTests.Timeshift_UrlShiftsStartToPortalClock;
begin
  // 19:30 UTC asked by the box -> 20:30 on a +60 portal
  Assert.AreEqual('http://prov.tv/timeshift/u/p/90/2026-11-12:20-30/4711.ts',
    XtreamTimeshiftUrl('http://prov.tv/ ', 'u', 'p', 90,
      EncodeDateTime(2026, 11, 12, 19, 30, 0, 0), 60, '4711', ''));
  Assert.AreEqual('http://prov.tv/timeshift/u/p/30/2026-11-12:23-45/9.m3u8',
    XtreamTimeshiftUrl('http://prov.tv', 'u', 'p', 30,
      EncodeDateTime(2026, 11, 13, 0, 45, 0, 0), -60, '9', 'm3u8'), 'crosses midnight backwards');
end;

procedure TUtilsTests.XtreamBase64_IsOneLine;
var
  lText: string;
  lEncoded: string;
begin
  lText := 'Met het laatste nieuws en de weersverwachting. En op NPO 1 Extra en NPO 2 met gebarentaal.';
  lEncoded := XtreamBase64(lText);
  Assert.IsFalse(lEncoded.Contains(#13) or lEncoded.Contains(#10), 'no line breaks');
  Assert.AreEqual(lText, TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(lEncoded)), 'round-trips');
  Assert.AreEqual('w6k=', XtreamBase64(#$00E9), 'UTF-8');
end;

procedure TUtilsTests.EpgKeys_MatchProviderAndGuideNames;
begin
  Assert.AreEqual('npo1', EpgNameKey('NL | NPO 1 HD'));
  Assert.AreEqual('npo1', EpgNameKey('NPO 1'));
  Assert.AreEqual('npo1', EpgIdKey('NPO.1.nl'));
  Assert.AreEqual('npo1', EpgIdKey('npo1.nl'));
  Assert.AreEqual('npo1', EpgIdKey('extra:NPO.1.nl'));
  // decorative record tag + heavy-bar country prefix
  Assert.AreEqual('nationalgeographic',
    EpgNameKey(#$2503'NL'#$2503' NATIONAL GEOGRAPHIC HD '#$23FA#$02B3#$1D49#$1D9C));
  Assert.AreEqual('nationalgeographic', EpgIdKey('natgeo.nl'), 'alias');
  Assert.AreEqual('nationalgeographicwild', EpgNameKey('NAT GEO WILD'));
  Assert.AreEqual('discovery', EpgNameKey('DISCOVERY CHANNEL'));
  Assert.AreEqual('ziggosport6', EpgNameKey('ZIGGO SPORT 6 HD'));
  Assert.AreEqual('ziggosport6', EpgIdKey('Ziggo.Sport.6.nl'));
  Assert.AreEqual('rtlz', EpgNameKey('NL| RTL Z'), 'single letter kept');
  Assert.AreEqual('bbcnl', EpgNameKey('BBC NL 8K'), 'trailing NL is part of the name');
  Assert.AreEqual('animalplanet', EpgNameKey('ANIMAL PLANET '#$0280#$1D00#$1D21' (S)'));
end;

procedure TUtilsTests.MaskUrlSecrets_HidesCredentials;
begin
  Assert.AreEqual('http://p.tv/player_api.php?username=***&password=***&action=x',
    MaskUrlSecrets('http://p.tv/player_api.php?username=bob&password=s3cr3t&action=x'));
  Assert.AreEqual('http://p.tv/live/***/***/123.ts', MaskUrlSecrets('http://p.tv/live/bob/s3cr3t/123.ts'));
  Assert.AreEqual('http://p.tv/timeshift/***/***/60/2026-11-12:20-30/9.ts',
    MaskUrlSecrets('http://p.tv/timeshift/bob/s3cr3t/60/2026-11-12:20-30/9.ts'));
  Assert.AreEqual('http://p.tv/xmltv.php?USERNAME=***&Password=***',
    MaskUrlSecrets('http://p.tv/xmltv.php?USERNAME=bob&Password=x'), 'case-insensitive');
  Assert.AreEqual('http://p.tv/guide.xml', MaskUrlSecrets('http://p.tv/guide.xml'), 'nothing to hide');
end;

procedure TUtilsTests.EpgIdKey_StripsOnlyCountryCodes;
begin
  Assert.AreEqual('bbcone', EpgIdKey('bbc.one.uk'));
  Assert.AreEqual('bbcone', EpgIdKey('bbc.one'), '"one" is not a country');
  Assert.AreEqual('sporthd', EpgIdKey('sport.hd'));
  Assert.AreEqual('rtl4', EpgIdKey('RTL.4.nl'));
end;

procedure TUtilsTests.FillMissingStops_UsesNextStart;
var
  lList: TEpgProgrammeList;

  function Add(const ACh: string; AStartH, AStopH: Integer): TEpgProgramme;
  begin
    Result := TEpgProgramme.Create;
    Result.ChannelTvgId := ACh;
    Result.StartUtc := EncodeDateTime(2026, 11, 13, AStartH, 0, 0, 0);
    if AStopH >= 0 then
      Result.StopUtc := EncodeDateTime(2026, 11, 13, AStopH, 0, 0, 0);
    lList.Add(Result);
  end;

begin
  lList := TEpgProgrammeList.Create(True);
  try
    Add('a', 10, -1);
    Add('b', 10, 11);
    Add('a', 12, -1);
    FillMissingStops(lList);
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 12, 0, 0, 0), lList[0].StopUtc, 'ends at the next start');
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 11, 0, 0, 0), lList[1].StopUtc, 'a real stop is kept');
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 13, 0, 0, 0), lList[2].StopUtc, 'the last gets an hour');
  finally
    FreeAndNil(lList);
  end;
end;

procedure TUtilsTests.XmltvAttr_BothQuoteStyles;
begin
  Assert.AreEqual('npo1.nl', AttrVal('<programme start="1" channel="npo1.nl">', 'channel'));
  Assert.AreEqual('npo1.nl', AttrVal('<programme start=''1'' channel=''npo1.nl''>', 'channel'));
  Assert.AreEqual('1', AttrVal('<programme vps-start="9" start="1">', 'start'), 'not inside vps-start');
  Assert.AreEqual('', AttrVal('<programme start="1">', 'channel'), 'absent');
end;

procedure TUtilsTests.FirstEpgUrl_TakesFirstOfList;
begin
  Assert.AreEqual('http://a/guide.xml', FirstEpgUrl(' http://a/guide.xml , http://b/g.xml.gz'));
  Assert.AreEqual('http://a/guide.xml', FirstEpgUrl('http://a/guide.xml'));
end;

procedure TUtilsTests.PublicBaseUrl_Normalised;
var
  lUrl: string;
begin
  Assert.IsTrue(NormalizePublicBaseUrl(' 192.168.1.10:9000/ ', lUrl));
  Assert.AreEqual('http://192.168.1.10:9000', lUrl, 'scheme added, slash dropped');
  Assert.IsTrue(NormalizePublicBaseUrl('https://tv.example.org', lUrl));
  Assert.AreEqual('https://tv.example.org', lUrl);
  Assert.IsTrue(NormalizePublicBaseUrl('', lUrl), 'empty = not configured');
  Assert.IsFalse(NormalizePublicBaseUrl('http://', lUrl), 'no host');
  Assert.AreEqual('localhost', SafeUrlHost('not a url', 'localhost'), 'never raises');
end;

procedure TUtilsTests.DecodeBytes_Latin1AndCyrillic;
var
  lBytes: TBytes;
begin
  // "Caf<e9> au lait" in ISO-8859-1 (not valid UTF-8)
  lBytes := TBytes.Create(Ord('C'), Ord('a'), Ord('f'), $E9, Ord(' '), Ord('a'), Ord('u'));
  Assert.AreEqual('Caf' + #$00E9 + ' au', DecodeBytes(lBytes), 'Western, not Cyrillic');
  // "Привет" in Windows-1251
  lBytes := TBytes.Create($CF, $F0, $E8, $E2, $E5, $F2);
  Assert.AreEqual(#$041F#$0440#$0438#$0432#$0435#$0442, DecodeBytes(lBytes));
end;

procedure TUtilsTests.SwapUrlExt_OnlyInPath;
begin
  Assert.AreEqual('http://p/live/u/p/1.m3u8', SwapUrlExt('http://p/live/u/p/1.ts', 'm3u8'));
  Assert.AreEqual('http://p/1.m3u8?t=a.b', SwapUrlExt('http://p/1.ts?t=a.b', 'm3u8'));
  Assert.AreEqual('mkv', UrlExt('http://p/movie/u/p/5.mkv?x=1'));
  Assert.AreEqual('php', UrlExt('http://p/play.php?id=5.ts'), 'a dot in the query is no extension');
end;

procedure TUtilsTests.ClientAllowList_IpsAndPrefixes;
begin
  Assert.IsTrue(IsClientInList('10.0.0.5', []), 'empty list = everyone');
  Assert.IsTrue(IsClientInList('192.168.1.20', ['192.168.1.20']));
  Assert.IsTrue(IsClientInList('::ffff:192.168.1.20', ['192.168.1.20']), 'IPv4-mapped');
  Assert.IsTrue(IsClientInList('192.168.1.77', ['192.168.1.']), 'prefix');
  Assert.IsFalse(IsClientInList('192.168.10.7', ['192.168.1.']), 'a prefix ends at the dot');
  Assert.IsFalse(IsClientInList('192.168.1.200', ['192.168.1.20']), 'exact means exact');
end;

procedure TUtilsTests.SamePassword_ConstantTimeCompare;
begin
  Assert.IsTrue(IsSamePassword('s3cret', 's3cret'));
  Assert.IsFalse(IsSamePassword('s3cre', 's3cret'));
  Assert.IsFalse(IsSamePassword('s3cretX', 's3cret'));
  Assert.IsFalse(IsSamePassword('', 's3cret'));
  Assert.IsTrue(IsSamePassword('пароль', 'пароль'), 'unicode');
end;

procedure TUtilsTests.UrlPathSafe_EscapesOnlyPathBreakers;
begin
  Assert.AreEqual('user', UrlPathSafe(' user '));
  Assert.AreEqual('a%2Fb%3Fc%23d%25e%20f', UrlPathSafe('a/b?c#d%e f'));
  Assert.AreEqual('p@ss+w!rd', UrlPathSafe('p@ss+w!rd'), 'everything else stays as typed');
end;

procedure TUtilsTests.AuthThrottle_LocksOutAfterTooManyFailures;
const
  cTestMaxFailures = 3;
  cTestWindowSec = 60;
  cTestLockoutSec = 60;
var
  lThrottle: TAuthThrottle;
  lRetryAfter, i: Integer;
begin
  lThrottle := TAuthThrottle.Create(cTestMaxFailures, cTestWindowSec, cTestLockoutSec);
  try
    for i := 1 to cTestMaxFailures - 1 do
      lThrottle.RegisterFailure('10.0.0.5');
    Assert.IsFalse(lThrottle.IsBlocked('10.0.0.5', lRetryAfter), 'below the limit');
    lThrottle.RegisterFailure('10.0.0.5');
    Assert.IsTrue(lThrottle.IsBlocked('10.0.0.5', lRetryAfter), 'limit reached');
    Assert.IsTrue((lRetryAfter > 0) and (lRetryAfter <= cTestLockoutSec), 'Retry-After in range');
    Assert.IsFalse(lThrottle.IsBlocked('10.0.0.6', lRetryAfter), 'another client is not affected');
    lThrottle.Reset;
    Assert.IsFalse(lThrottle.IsBlocked('10.0.0.5', lRetryAfter));
  finally
    FreeAndNil(lThrottle);
  end;
end;

procedure TUtilsTests.Ssdp_RepliesWithTheRequestedSearchTarget;
const
  cProbeHead = 'M-SEARCH * HTTP/1.1'#13#10'HOST: 239.255.255.250:1900'#13#10 +
    'MAN: "ssdp:discover"'#13#10'MX: 1'#13#10;
var
  lTargets: TArray<string>;
  lReply: string;
begin
  lTargets := SsdpReplyTargets(cProbeHead + 'ST: urn:schemas-upnp-org:device:MediaServer:1'#13#10#13#10);
  Assert.AreEqual<Integer>(1, Length(lTargets));
  Assert.AreEqual('urn:schemas-upnp-org:device:MediaServer:1', lTargets[0], 'echoed');
  lTargets := SsdpReplyTargets(cProbeHead + 'st: ssdp:all'#13#10#13#10);
  Assert.AreEqual<Integer>(2, Length(lTargets), 'ssdp:all -> each type we provide');
  lTargets := SsdpReplyTargets(cProbeHead + 'ST: urn:dial-multiscreen-org:service:dial:1'#13#10#13#10);
  Assert.AreEqual<Integer>(0, Length(lTargets), 'not ours: no answer');
  lTargets := SsdpReplyTargets('NOTIFY * HTTP/1.1'#13#10'ST: ssdp:all'#13#10#13#10);
  Assert.AreEqual<Integer>(0, Length(lTargets), 'not a discovery probe');
  lReply := BuildSsdpReply('http://10.0.0.2:7777/discover.json', 'upnp:rootdevice');
  Assert.IsTrue(lReply.Contains(#13#10'ST: upnp:rootdevice'#13#10));
  Assert.IsTrue(lReply.Contains('::upnp:rootdevice'#13#10), 'USN matches the ST');
  Assert.IsTrue(lReply.Contains('LOCATION: http://10.0.0.2:7777/discover.json'));
end;

initialization
  TDUnitX.RegisterTestFixture(TUtilsTests);

end.
