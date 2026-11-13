unit Test.Utils;

{ Tests for IPTV.Core.Utils: content-type CSV and ISO-8601 UTC round-trips. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TUtilsTests = class
  public
    [Test] procedure ContentTypesRoundtrip;
    [Test] procedure ContentTypesParseIgnoresBlanks;
    [Test] procedure IsoDateRoundtrip;
    [Test] procedure EmptyDateIsZero;
    [Test] procedure StripPrefix_HandlesPipeAndSpaceVariants;
    [Test] procedure StripPrefix_HandlesUnicodeVerticalBars;
    [Test] procedure StripPrefix_RequiresWordBoundary;
    [Test] procedure StripPrefix_IsCaseInsensitiveAndTrims;
    [Test] procedure StripPrefix_StripsMultiplePrefixes;
    [Test] procedure StripPrefix_NoTokensOrNoMatchLeavesNameTrimmed;
    [Test] procedure Quality_DetectsAndStripsTrailingToken;
    [Test] procedure Quality_VariantsShareBaseKey;
    [Test] procedure Quality_PlusTiersAreDistinct;
    [Test] procedure Quality_NoneLeavesNameAsBase;
    [Test] procedure Quality_CanonicalMapsSynonyms;
    [Test] procedure Quality_SmallCapsRawIsAQuality;
    [Test] procedure Quality_HeadKeyIgnoresTagsAfterQuality;
    [Test] procedure StripSuffix_RemovesTrailingTags;
    [Test] procedure StripSuffix_RequiresWordBoundaryAndKeepsName;
    [Test] procedure CleanChannelName_PrefixAndSuffix;
    [Test] procedure Timeshift_ParsesWireAndOtherForms;
    [Test] procedure Timeshift_PortalOffsetFromServerInfo;
    [Test] procedure Timeshift_UrlShiftsStartToPortalClock;
    [Test] procedure XtreamBase64_IsOneLine;
    [Test] procedure EpgKeys_MatchProviderAndGuideNames;
  end;

implementation

uses
  System.SysUtils, System.DateUtils, System.NetEncoding,
  IPTV.Model.Types, IPTV.Core.Utils;

procedure TUtilsTests.ContentTypesRoundtrip;
var
  CT: TContentTypes;
begin
  CT := [ctLive, ctSeries];
  Assert.IsTrue(CT = StrToContentTypes(ContentTypesToStr(CT)));
  Assert.IsTrue(AllContentTypes = StrToContentTypes(ContentTypesToStr(AllContentTypes)));
end;

procedure TUtilsTests.ContentTypesParseIgnoresBlanks;
begin
  Assert.IsTrue([ctLive, ctRadio] = StrToContentTypes(' live , , radio '));
end;

procedure TUtilsTests.IsoDateRoundtrip;
var
  Dt: TDateTime;
begin
  Dt := EncodeDateTime(2026, 6, 14, 18, 30, 0, 0);
  Assert.AreEqual(Dt, IsoUtcToDateTime(DateTimeToIsoUtc(Dt)), 1.0 / 86400);
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
  Q: string;
begin
  Assert.AreEqual('nl npo 1', QualityMatchKey('NL| NPO 1 HD', Q));
  Assert.AreEqual('HD', Q);
  Assert.AreEqual('espn 1', QualityMatchKey('ESPN 1 UHD', Q));
  Assert.AreEqual('UHD', Q);
end;

procedure TUtilsTests.Quality_VariantsShareBaseKey;
var
  Qa, Qb: string;
begin
  // the whole point: HD and UHD of one channel key to the same base
  Assert.AreEqual(QualityMatchKey('NL| NPO 1 HD', Qa), QualityMatchKey('NL| NPO 1 UHD', Qb));
  Assert.AreEqual('HD', Qa);
  Assert.AreEqual('UHD', Qb);
end;

procedure TUtilsTests.Quality_PlusTiersAreDistinct;
var
  Q: string;
begin
  // "4K+" must canonicalise as a tier distinct from "4K"
  Assert.AreEqual('film1 action', QualityMatchKey('Film1 Action 4K+', Q));
  Assert.AreEqual('4K+', Q);
  Assert.AreEqual('4K', CanonicalQuality('4k'));
  Assert.AreNotEqual('4K', CanonicalQuality('4k+'));
end;

procedure TUtilsTests.Quality_NoneLeavesNameAsBase;
var
  Q: string;
begin
  // no quality word → quality empty, base is the (lowercased) name
  Assert.AreEqual('discovery channel', QualityMatchKey('Discovery Channel', Q));
  Assert.AreEqual('', Q);
  // a quality-looking substring inside a word is NOT a token ("HD" in "HDNET")
  Assert.AreEqual('hdnet', QualityMatchKey('HDNET', Q));
  Assert.AreEqual('', Q);
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
  Qa, Qb: string;
begin
  Assert.AreEqual('RAW', CanonicalQuality(RAW_SC));
  Assert.AreEqual('RAW', CanonicalQuality('raw'));
  // a RAW channel and its 4K+ variant share the base key
  Assert.AreEqual(QualityMatchKey('NL | NPO 1 ' + RAW_SC, Qa), QualityMatchKey('NL | NPO 1 4K+', Qb));
  Assert.AreEqual('RAW', Qa);
  Assert.AreEqual('4K+', Qb);
  // decorative letters in the rest of the name are folded too
  Assert.AreEqual('npo 1 rec', QualityMatchKey('NPO 1 HD ' + REC_SUP, Qa));
end;

procedure TUtilsTests.Quality_HeadKeyIgnoresTagsAfterQuality;
var
  Q, Head: string;
begin
  Assert.AreEqual('nl history s', QualityMatchKey('NL | HISTORY ' + RAW_SC + ' (S)', Q, Head));
  Assert.AreEqual('nl history', Head);
  Assert.AreEqual('RAW', Q);
  // nothing after the quality: head = base
  Assert.AreEqual('nl npo 1', QualityMatchKey('NL | NPO 1 4K+', Q, Head));
  Assert.AreEqual('nl npo 1', Head);
  // no quality: head = base
  QualityMatchKey('Discovery Channel', Q, Head);
  Assert.AreEqual('discovery channel', Head);
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
  D: TDateTime;
begin
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12:20-30', D));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), D, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12:20-30-15', D));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 15, 0), D, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart('2026-11-12 20:30:00', D));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), D, 1 / 86400);
  Assert.IsTrue(ParseTimeshiftStart(IntToStr(DateTimeToUnix(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), True)), D));
  Assert.AreEqual(EncodeDateTime(2026, 11, 12, 20, 30, 0, 0), D, 1 / 86400);
  Assert.IsFalse(ParseTimeshiftStart('', D));
  Assert.IsFalse(ParseTimeshiftStart('2026-13-40:20-30', D), 'invalid date');
  Assert.IsFalse(ParseTimeshiftStart('yesterday', D));
  Assert.AreEqual('2026-11-12:20-30', FormatTimeshiftStart(EncodeDateTime(2026, 11, 12, 20, 30, 59, 0)));
end;

procedure TUtilsTests.Timeshift_PortalOffsetFromServerInfo;
var
  M: Integer;
  U: Int64;
begin
  U := DateTimeToUnix(EncodeDateTime(2026, 11, 13, 13, 0, 0, 0), True);
  // CET portal: local 14:00:02 while UTC is 13:00 -> +60 (rounded to 15 min)
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 14:00:02', U, M));
  Assert.AreEqual(60, M);
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 08:00:00', U, M));
  Assert.AreEqual(-300, M, 'US east');
  Assert.IsTrue(XtreamTzOffsetMin('2026-11-13 13:00:00', U, M));
  Assert.AreEqual(0, M);
  Assert.IsFalse(XtreamTzOffsetMin('', U, M), 'no time_now');
  Assert.IsFalse(XtreamTzOffsetMin('2026-11-13 14:00:00', 0, M), 'no timestamp_now');
  Assert.IsFalse(XtreamTzOffsetMin('2026-11-20 14:00:00', U, M), 'a week off is nonsense');
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
  Long, B: string;
begin
  Long := 'Met het laatste nieuws en de weersverwachting. En op NPO 1 Extra en NPO 2 met gebarentaal.';
  B := XtreamBase64(Long);
  Assert.IsFalse(B.Contains(#13) or B.Contains(#10), 'no line breaks');
  Assert.AreEqual(Long, TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(B)), 'round-trips');
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
  Assert.AreEqual('nationalgeographic', EpgNameKey(#$2503'NL'#$2503' NATIONAL GEOGRAPHIC HD '#$23FA#$02B3#$1D49#$1D9C));
  Assert.AreEqual('nationalgeographic', EpgIdKey('natgeo.nl'), 'alias');
  Assert.AreEqual('nationalgeographicwild', EpgNameKey('NAT GEO WILD'));
  Assert.AreEqual('discovery', EpgNameKey('DISCOVERY CHANNEL'));
  Assert.AreEqual('ziggosport6', EpgNameKey('ZIGGO SPORT 6 HD'));
  Assert.AreEqual('ziggosport6', EpgIdKey('Ziggo.Sport.6.nl'));
  Assert.AreEqual('rtlz', EpgNameKey('NL| RTL Z'), 'single letter kept');
  Assert.AreEqual('bbcnl', EpgNameKey('BBC NL 8K'), 'trailing NL is part of the name');
  Assert.AreEqual('animalplanet', EpgNameKey('ANIMAL PLANET '#$0280#$1D00#$1D21' (S)'));
end;

initialization
  TDUnitX.RegisterTestFixture(TUtilsTests);

end.
