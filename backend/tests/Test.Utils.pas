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
    /// <summary>A duplicate start without stop never keeps StopUtc = 0.</summary>
    [Test] procedure FillMissingStops_DuplicateStartGetsAStop;
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
    /// <summary>Mirror playback: the /USER/PASS/ path segment gets the new account.</summary>
    [Test] procedure RewriteProviderUrl_XtreamPath;
    /// <summary>Mirror playback: the M3U query values get the new account, URL-encoded.</summary>
    [Test] procedure RewriteProviderUrl_M3uQuery;
    /// <summary>Mirror playback: a new server replaces only the source's base.</summary>
    [Test] procedure RewriteProviderUrl_NewServer;
    /// <summary>Mirror playback: only the overridden parts change.</summary>
    [Test] procedure RewriteProviderUrl_PartialOverrides;
    /// <summary>Mirror playback: an unrecognised URL stays as is.</summary>
    [Test] procedure RewriteProviderUrl_UnrecognisedUnchanged;
    /// <summary>Credentials in URLs are masked.</summary>
    [Test] procedure MaskUrlSecrets_HidesCredentials;
    /// <summary>The short Xtream form host/USER/PASS/123.ext is masked too (also in a message).</summary>
    [Test] procedure MaskUrlSecrets_HidesShortXtreamPath;
    /// <summary>MaskUrlQuerySecrets hides only the values of the secret query keys.</summary>
    [Test] procedure MaskUrlQuerySecrets_HidesSecretValues;
    /// <summary>RestoreMaskedUrlSecrets puts the stored values back for '***' and drops unknown ones.</summary>
    [Test] procedure RestoreMaskedUrlSecrets_RestoresStored;
    /// <summary>Only ts/m3u8 may be swapped into a live URL; anything else is ''.</summary>
    [Test] procedure LiveRequestExt_OnlyTsAndHls;
    /// <summary>The relay file name is rebuilt from the stream id + a safe extension.</summary>
    [Test] procedure RelayStreamFileName_FromResolvedId;
    /// <summary>Forced HLS only counts when the URL really is a playlist.</summary>
    [Test] procedure IsHlsUrl_ByPathExtension;
    /// <summary>The strict content-type parse rejects unknown names.</summary>
    [Test] procedure TryContentTypeFromString_Strict;
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

procedure TUtilsTests.MaskUrlQuerySecrets_HidesSecretValues;
begin
  Assert.AreEqual('http://p/get.php?username=bob&password=***&type=m3u_plus',
    MaskUrlQuerySecrets('http://p/get.php?username=bob&password=s3&type=m3u_plus'), 'username stays');
  Assert.AreEqual('http://p/x?PASS=***&Pwd=***&TOKEN=***&key=***&ApiKey=***&api_key=***#frag',
    MaskUrlQuerySecrets('http://p/x?PASS=a&Pwd=b&TOKEN=c&key=d&ApiKey=e&api_key=f#frag'), 'all keys, any case');
  Assert.AreEqual('http://p/x?password=&monkey=1&keyword=k',
    MaskUrlQuerySecrets('http://p/x?password=&monkey=1&keyword=k'), 'empty value + look-alike keys stay');
  Assert.AreEqual('http://p/live/bob/pw/1.ts', MaskUrlQuerySecrets('http://p/live/bob/pw/1.ts'), 'no query');
  Assert.AreEqual('http://p/a#x?token=1', MaskUrlQuerySecrets('http://p/a#x?token=1'), '? inside the fragment');
  Assert.AreEqual('', MaskUrlQuerySecrets(''));
end;

procedure TUtilsTests.RestoreMaskedUrlSecrets_RestoresStored;
const
  cStored = 'http://p/get.php?username=bob&password=s%26cret&token=t1';
begin
  Assert.AreEqual(cStored, RestoreMaskedUrlSecrets(MaskUrlQuerySecrets(cStored), cStored), 'round trip');
  Assert.AreEqual('http://q/get.php?username=ann&password=s%26cret&token=t1',
    RestoreMaskedUrlSecrets('http://q/get.php?username=ann&password=***&token=***', cStored),
    'other parts edited, secrets kept');
  Assert.AreEqual('http://p/get.php?username=bob&password=new&token=t1',
    RestoreMaskedUrlSecrets('http://p/get.php?username=bob&password=new&token=***', cStored), 'a new value wins');
  Assert.AreEqual('http://p/get.php?username=bob&PASSWORD=s%26cret',
    RestoreMaskedUrlSecrets('http://p/get.php?username=bob&PASSWORD=%2A%2A%2A&key=***', cStored),
    'case-insensitive, encoded mask, a param absent in the stored URL is dropped');
  Assert.AreEqual('http://p/xmltv.php#f', RestoreMaskedUrlSecrets('http://p/xmltv.php?apikey=***#f', ''),
    'nothing left: no "?"');
  Assert.AreEqual('http://p/x?a=1', RestoreMaskedUrlSecrets('http://p/x?a=1', cStored), 'nothing masked');
end;

procedure TUtilsTests.MaskUrlSecrets_HidesShortXtreamPath;
begin
  Assert.AreEqual('http://p.tv:8080/***/***/123.ts', MaskUrlSecrets('http://p.tv:8080/bob/s3cr3t/123.ts'));
  Assert.AreEqual('http://p.tv/***/***/123.m3u8', MaskUrlSecrets('http://p.tv/bob/s3cr3t/123.m3u8'));
  Assert.AreEqual('http://p.tv/***/***/123', MaskUrlSecrets('http://p.tv/bob/s3cr3t/123'), 'no extension');
  Assert.AreEqual('http://p.tv/***/***/77.mp4?token=***', MaskUrlSecrets('http://p.tv/bob/pw/77.mp4?token=abc'));
  Assert.AreEqual('HTTP 403 fetching http://p.tv/***/***/5.ts (x)',
    MaskUrlSecrets('HTTP 403 fetching http://p.tv/bob/pw/5.ts (x)'), 'inside a message');
  Assert.AreEqual('http://p.tv/stream/***/***/5.ts', MaskUrlSecrets('http://p.tv/stream/bob/pw/5.ts'));
  Assert.AreEqual('http://p.tv/movie/***/***/9.mkv', MaskUrlSecrets('http://p.tv/movie/bob/pw/9.mkv'),
    'typed path once, not twice');
  Assert.AreEqual('http://p.tv/logos/nl/npo1.png', MaskUrlSecrets('http://p.tv/logos/nl/npo1.png'),
    'a non-numeric file name is no Xtream stream');
end;

procedure TUtilsTests.LiveRequestExt_OnlyTsAndHls;
begin
  Assert.AreEqual('ts', LiveRequestExt('ts'));
  Assert.AreEqual('ts', LiveRequestExt('TS'));
  Assert.AreEqual('m3u8', LiveRequestExt('M3U8'));
  Assert.AreEqual('', LiveRequestExt('mp4'));
  Assert.AreEqual('', LiveRequestExt('ts/../x'));
  Assert.AreEqual('', LiveRequestExt(''));
end;

procedure TUtilsTests.RelayStreamFileName_FromResolvedId;
begin
  Assert.AreEqual('42.ts', RelayStreamFileName(42, 'ts'));
  Assert.AreEqual('42.m3u8', RelayStreamFileName(42, 'm3u8'));
  Assert.AreEqual('42.mkv', RelayStreamFileName(42, 'mkv'), 'a movie container');
  Assert.AreEqual('42.ts', RelayStreamFileName(42, ''), 'none -> ts');
  Assert.AreEqual('42.ts', RelayStreamFileName(42, 'ts/../../x'), 'path junk -> ts');
  Assert.AreEqual('42.ts', RelayStreamFileName(42, 'ts%0d%0aX'), 'header junk -> ts');
end;

procedure TUtilsTests.IsHlsUrl_ByPathExtension;
begin
  Assert.IsTrue(IsHlsUrl('http://p/live/u/p/1.m3u8'));
  Assert.IsTrue(IsHlsUrl('http://p/live/u/p/1.M3U8?token=x'));
  Assert.IsFalse(IsHlsUrl('http://p/1.ts'), 'an M3U source''s .ts stays .ts');
  Assert.IsFalse(IsHlsUrl('http://p/radio.mp3'));
  Assert.IsFalse(IsHlsUrl('http://p/play.php?f=x.m3u8'), 'only the path counts');
end;

procedure TUtilsTests.TryContentTypeFromString_Strict;
var
  lType: TContentType;
begin
  Assert.IsTrue(TryContentTypeFromString('Movie', lType));
  Assert.AreEqual(Ord(ctMovie), Ord(lType));
  Assert.IsTrue(TryContentTypeFromString('radio', lType));
  Assert.AreEqual(Ord(ctRadio), Ord(lType));
  Assert.IsFalse(TryContentTypeFromString('films', lType), 'unknown');
  Assert.IsFalse(TryContentTypeFromString('', lType), 'empty');
  Assert.AreEqual(Ord(ctLive), Ord(ContentTypeFromString('films')), 'the lenient parse is unchanged');
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

procedure TUtilsTests.FillMissingStops_DuplicateStartGetsAStop;
var
  lList: TEpgProgrammeList;

  procedure Add(const ACh: string; AStartH: Integer);
  var
    lProg: TEpgProgramme;
  begin
    lProg := TEpgProgramme.Create;
    lProg.ChannelTvgId := ACh;
    lProg.StartUtc := EncodeDateTime(2026, 11, 13, AStartH, 0, 0, 0);
    lList.Add(lProg);
  end;

begin
  lList := TEpgProgrammeList.Create(True);
  try
    Add('a', 10);
    Add('a', 10); // the guide lists the same programme twice
    Add('a', 12);
    Add('a', 14);
    Add('a', 14); // a duplicate of the last one too
    FillMissingStops(lList);
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 12, 0, 0, 0), lList[0].StopUtc, 'ends at the next start');
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 12, 0, 0, 0), lList[1].StopUtc, 'so does the duplicate');
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 14, 0, 0, 0), lList[2].StopUtc);
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 15, 0, 0, 0), lList[3].StopUtc, 'the last gets an hour');
    Assert.AreEqual(EncodeDateTime(2026, 11, 13, 15, 0, 0, 0), lList[4].StopUtc, 'its duplicate too');
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

const
  cRwSrc = 'http://prov.tv:8080';
  cRwLive = 'http://prov.tv:8080/live/u1/p1/4711.ts';

procedure TUtilsTests.RewriteProviderUrl_XtreamPath;
begin
  Assert.AreEqual('http://prov.tv:8080/live/u2/p2/4711.ts',
    RewriteProviderUrl(cRwLive, cRwSrc, 'u1', 'p1', '', 'u2', 'p2'));
  Assert.AreEqual('http://prov.tv:8080/movie/u2/p2/9.mkv',
    RewriteProviderUrl('http://prov.tv:8080/movie/u1/p1/9.mkv', cRwSrc, 'u1', 'p1', '', 'u2', 'p2'));
  // escaped in the stored URL, escaped in the result
  Assert.AreEqual('http://prov.tv:8080/live/u2/n%2Fw%20x/1.ts',
    RewriteProviderUrl('http://prov.tv:8080/live/u1/a%2Fb/1.ts', cRwSrc, 'u1', 'a/b', '', 'u2', 'n/w x'));
  // the host is never mistaken for the account (search starts after the authority)
  Assert.AreEqual('http://u1/live/u2/p2/1.ts',
    RewriteProviderUrl('http://u1/live/u1/p1/1.ts', 'http://u1', 'u1', 'p1', '', 'u2', 'p2'));
end;

procedure TUtilsTests.RewriteProviderUrl_M3uQuery;
const
  cSrc = 'http://m3u.tv/get.php?username=u1&password=p1&type=m3u_plus';
begin
  Assert.AreEqual('http://m3u.tv/play.php?username=u2&password=p%26%202&id=7',
    RewriteProviderUrl('http://m3u.tv/play.php?username=u1&password=p1&id=7', cSrc, '', '', '', 'u2', 'p& 2'));
  // the account comes from the source URL's query: Xtream-style paths follow too
  Assert.AreEqual('http://m3u.tv/u2/p2/7',
    RewriteProviderUrl('http://m3u.tv/u1/p1/7', cSrc, '', '', '', 'u2', 'p2'));
end;

procedure TUtilsTests.RewriteProviderUrl_NewServer;
begin
  Assert.AreEqual('https://other.tv/live/u2/p2/4711.ts',
    RewriteProviderUrl(cRwLive, cRwSrc + '/', 'u1', 'p1', 'https://other.tv/', 'u2', 'p2'));
  Assert.AreEqual('http://other.tv:81/live/u1/p1/4711.ts',
    RewriteProviderUrl(cRwLive, cRwSrc, 'u1', 'p1', 'other.tv:81', '', ''), 'no scheme: http');
  Assert.AreEqual('http://other.tv/live/u1/p1/4711.ts',
    RewriteProviderUrl('HTTP://PROV.TV:8080/live/u1/p1/4711.ts', cRwSrc, 'u1', 'p1', 'http://other.tv/x', '', ''),
    'case-insensitive base; only the new base is used');
  // another port is another base: left alone
  Assert.AreEqual('http://prov.tv:80801/live/u1/p1/1.ts',
    RewriteProviderUrl('http://prov.tv:80801/live/u1/p1/1.ts', cRwSrc, 'u1', 'p1', 'http://other.tv', '', ''));
end;

procedure TUtilsTests.RewriteProviderUrl_PartialOverrides;
begin
  Assert.AreEqual('http://prov.tv:8080/live/u2/p1/4711.ts',
    RewriteProviderUrl(cRwLive, cRwSrc, 'u1', 'p1', '', 'u2', ''), 'only the username');
  Assert.AreEqual('http://prov.tv:8080/live/u1/p2/4711.ts',
    RewriteProviderUrl(cRwLive, cRwSrc, 'u1', 'p1', '', '', 'p2'), 'only the password');
  Assert.AreEqual(cRwLive, RewriteProviderUrl(cRwLive, cRwSrc, 'u1', 'p1', '', '', ''), 'nothing overridden');
end;

procedure TUtilsTests.RewriteProviderUrl_UnrecognisedUnchanged;
const
  cForeign = 'http://cdn.example/hls/abc/index.m3u8';
begin
  Assert.AreEqual(cForeign, RewriteProviderUrl(cForeign, cRwSrc, 'u1', 'p1', 'http://other.tv', 'u2', 'p2'));
  Assert.AreEqual('', RewriteProviderUrl('', cRwSrc, 'u1', 'p1', 'http://other.tv', 'u2', 'p2'));
  Assert.AreEqual('not a url', RewriteProviderUrl('not a url', cRwSrc, 'u1', 'p1', 'http://other.tv', 'u2', 'p2'));
end;

initialization
  TDUnitX.RegisterTestFixture(TUtilsTests);

end.
