unit IPTV.Source.Epg;

{ XMLTV reader WITHOUT a DOM. Provider guides are routinely 100+ MB with
  hundreds of thousands of <programme> entries — MSXML/DOM can't cope (it builds
  millions of node objects and dies). Instead we fetch the document and scan it
  linearly for <programme ...>...</programme> blocks, extracting attributes and
  the <title>/<desc> text by hand, keeping only programmes for the channels we
  actually carry (AKeepTvgIds).

  Source of the XMLTV URL:
    - explicit TSourceConfig.EpgUrl if set;
    - else Xtream:  <base>/xmltv.php?username=U&password=P
    - else M3U: the url-tvg attribute discovered during M3U ingest.

  XMLTV timestamps look like "20260614180000 +0200"; parsed to UTC. }

interface

uses
  // RTL
  System.SysUtils,
  // Own units
  IPTV.Model.Source,
  IPTV.Model.Epg,
  IPTV.Source.Intf;

type
  /// DOM-less XMLTV reader for a source's guide, filtered to the wanted tvg-ids.
  TXmltvEpgReader = class(TInterfacedObject, IEpgReader)
  private
    function ResolveUrl(const ASource: TSourceConfig): string;
    function ParseXmltvTime(const AValue: string): TDateTime;
  public
    function Read(const ASource: TSourceConfig; const AKeepTvgIds: TArray<string>): TEpgProgrammeList;
  end;

/// Read a whole third-party XMLTV guide (an "extra EPG source", .xml or .xml.gz):
/// every <channel> (id + first display-name) and every programme. Programme
/// channel ids get EXTRA_EPG_PREFIX and SourceId = ASourceId (a negative slot id).
/// AKeepChannel (optional) decides per <channel> whether its programmes are kept;
/// the others are skipped while scanning (a big guide never sits fully in memory).
/// AChannels always lists every channel.
function ReadExtraXmltv(const AUrl: string; ASourceId: Integer;
  out AChannels: TArray<TEpgChannelInfo>;
  const AKeepChannel: TFunc<TEpgChannelInfo, Boolean> = nil): TEpgProgrammeList;

/// XMLTV allows a programme without stop: it then ends where the next programme
/// of the same channel starts (the last one gets an hour). In list order.
procedure FillMissingStops(AList: TEpgProgrammeList);

/// Value of attribute AName in one XML tag/block (double or single quotes), '' if absent.
function AttrVal(const ABlock, AName: string): string;

/// The first URL of an EPG setting / M3U url-tvg (it may list several, comma-separated).
function FirstEpgUrl(const AValue: string): string;

implementation

uses
  // RTL
  System.Classes,
  System.DateUtils,
  System.StrUtils,
  System.Math,
  System.Character,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.NetEncoding,
  // Own units
  IPTV.Model.Types,
  IPTV.Source.Http;

const
  // XMLTV tags / attributes
  cTagProgrammeOpen = '<programme';
  cTagProgrammeClose = '</programme>';
  cTagChannelOpen = '<channel';
  cTagChannelClose = '</channel>';
  cTagTitle = 'title';
  cTagDesc = 'desc';
  cTagDisplayName = 'display-name';
  cAttrChannel = 'channel';
  cAttrStart = 'start';
  cAttrStop = 'stop';
  cAttrId = 'id';

  // XMLTV timestamp zone suffix ("+HH" / "+HHMM", colon already removed)
  cTzHoursLen = 3;
  cTzFullLen = 5;

  // a programme without stop that is the last of its channel lasts this long
  cDefaultLastProgrammeHours = 1;

  // numeric character references (&#233; / &#xE9;)
  cCharRefPrefix = '&#';
  cUnicodeMax = $10FFFF;
  cSurrogateFirst = $D800;
  cSurrogateLast = $DFFF;

function TXmltvEpgReader.ResolveUrl(const ASource: TSourceConfig): string;
begin
  if ASource.EpgUrl.Trim <> '' then
    // url-tvg may list several guides ("a.xml,b.xml.gz"): use the first
    Exit(FirstEpgUrl(ASource.EpgUrl));
  if ASource.Kind = skXtream then
    // trimmed like every other Xtream URL: a stray space in the password made only
    // the guide fail (silently: "EPG empty - kept the previous guide")
    Result := Format('%s/xmltv.php?username=%s&password=%s',
      [ASource.Url.Trim.TrimRight(['/']),
       TNetEncoding.URL.Encode(ASource.Username.Trim),
       TNetEncoding.URL.Encode(ASource.Password.Trim)])
  else
    Result := '';
end;

function FirstEpgUrl(const AValue: string): string;
var
  lParts: TArray<string>;
  lPart: string;
begin
  Result := AValue.Trim;
  lParts := AValue.Split([',']);
  for lPart in lParts do
    if lPart.Trim <> '' then
      Exit(lPart.Trim);
end;

function TXmltvEpgReader.ParseXmltvTime(const AValue: string): TDateTime;
const
  cXmltvMinDigits = 12; // YYYYMMDDHHMM (seconds optional)
  cXmltvFullDigits = 14; // YYYYMMDDHHMMSS
var
  lStr, lDigits, lTzPart: string;
  lYear, lMonth, lDay, lHour, lMinute, lSecond: Word;
  lOffSign, lOffHours, lOffMinutes, lLen: Integer;
  lLocal: TDateTime;
begin
  // "YYYYMMDDHHMM[SS] [±HH[[:]MM]]" -> UTC. The zone may follow without a space
  // ("20261113120000+0100") and may be hours only ("+01").
  lStr := AValue.Trim;
  lLen := 0;
  while (lLen < lStr.Length) and CharInSet(lStr.Chars[lLen], ['0'..'9']) do
    Inc(lLen);
  lDigits := lStr.Substring(0, lLen);
  // accept both "±HHMM" and the colon form "±HH:MM" (half-hour zones keep minutes)
  lTzPart := lStr.Substring(lLen).Trim.Replace(':', '');
  if lDigits.Length < cXmltvMinDigits then
    Exit(0);
  lYear := StrToIntDef(lDigits.Substring(0, 4), 0);
  lMonth := StrToIntDef(lDigits.Substring(4, 2), 1);
  lDay := StrToIntDef(lDigits.Substring(6, 2), 1);
  lHour := StrToIntDef(lDigits.Substring(8, 2), 0);
  lMinute := StrToIntDef(lDigits.Substring(10, 2), 0);
  if lDigits.Length >= cXmltvFullDigits then
    lSecond := StrToIntDef(lDigits.Substring(12, 2), 0)
  else
    lSecond := 0;
  // a single malformed timestamp (e.g. month 13) must NOT abort the whole EPG
  // read — return 0 and let the caller skip just this value
  if not TryEncodeDateTime(lYear, lMonth, lDay, lHour, lMinute, lSecond, 0, lLocal) then
    Exit(0);
  Result := lLocal;
  if (lTzPart.Length >= cTzHoursLen) and CharInSet(lTzPart.Chars[0], ['+', '-']) then
  begin
    // to UTC
    if lTzPart.Chars[0] = '-' then
      lOffSign := 1
    else
      lOffSign := -1;
    lOffHours := StrToIntDef(lTzPart.Substring(1, 2), 0);
    lOffMinutes := 0;
    if lTzPart.Length >= cTzFullLen then
      lOffMinutes := StrToIntDef(lTzPart.Substring(3, 2), 0);
    Result := IncMinute(lLocal, lOffSign * (lOffHours * MinsPerHour + lOffMinutes));
  end;
end;

// minimal XML helpers (no DOM)

// Find `AName="` within AXml in the window [AFrom, ATo), but ONLY at a real
// attribute boundary — the char before it must be whitespace or '<'. Without this
// a bare substring search makes 'start' match inside 'vps-start="..."' /
// 'pdc-start="..."' (both valid XMLTV <programme> attributes) and read the wrong
// value. Returns the position just AFTER the opening quote, or 0 if not found.
// Both quote styles are valid XML (name="v" and name='v'); AQuote returns the one used.
function FindAttrValueStart(const AXml, AName: string; AFrom, ATo: Integer;
  out AQuote: Char): Integer;
var
  lPos, lLen, lLast: Integer;
  lQuote: Char;
begin
  // walk ONLY the window [AFrom, ATo): a PosEx for a needle that isn't in this
  // block would scan to the end of a 100+ MB guide - per programme
  lLen := Length(AName);
  lLast := Min(ATo, Length(AXml) + 1) - lLen - 2; // room for name + '=' + quote
  lPos := Max(AFrom, 1);
  while lPos <= lLast do
  begin
    if (AXml[lPos] = AName[1]) and (AXml[lPos + lLen] = '=') and
       ((lPos = 1) or CharInSet(AXml[lPos - 1], [' ', #9, #10, #13, '<'])) and
       CompareMem(@AXml[lPos], @AName[1], lLen * SizeOf(Char)) then
    begin
      lQuote := AXml[lPos + lLen + 1];
      if (lQuote = '"') or (lQuote = '''') then
      begin
        AQuote := lQuote;
        Exit(lPos + lLen + 2);
      end;
    end;
    Inc(lPos);
  end;
  AQuote := '"';
  Result := 0;
end;

function AttrVal(const ABlock, AName: string): string;
var
  lPos, lEnd: Integer;
  lQuote: Char;
begin
  Result := '';
  lPos := FindAttrValueStart(ABlock, AName, 1, Length(ABlock) + 1, lQuote);
  if lPos = 0 then
    Exit;
  lEnd := PosEx(lQuote, ABlock, lPos);
  if lEnd > 0 then
    Result := Copy(ABlock, lPos, lEnd - lPos);
end;

// Read an attribute IN PLACE from a window [AFrom, ATo) of the big XML string,
// without first copying the whole block. Used for the channel filter so we only
// allocate a per-programme substring for the channels we actually keep — a full
// provider guide has hundreds of thousands of <programme>s we discard, and
// copying each one just to read 'channel' was the main allocation churn (and the
// memory the manager held onto after a refresh).
function AttrValIn(const AXml, AName: string; AFrom, ATo: Integer): string;
var
  lPos, lEnd: Integer;
  lQuote: Char;
begin
  Result := '';
  lPos := FindAttrValueStart(AXml, AName, AFrom, ATo, lQuote);
  if lPos = 0 then
    Exit;
  lEnd := PosEx(lQuote, AXml, lPos);
  if (lEnd > 0) and (lEnd <= ATo) then
    Result := Copy(AXml, lPos, lEnd - lPos);
end;

function TagText(const ABlock, ATag: string): string;
var
  lOpen, lGt, lClose: Integer;
begin
  Result := '';
  lOpen := Pos('<' + ATag, ABlock);
  if lOpen = 0 then
    Exit;
  lGt := PosEx('>', ABlock, lOpen);
  if lGt = 0 then
    Exit;
  lClose := PosEx('</' + ATag + '>', ABlock, lGt);
  if lClose = 0 then
    Exit;
  Result := Copy(ABlock, lGt + 1, lClose - lGt - 1);
end;

function XmlDecode(const AValue: string): string;
var
  lPos, lSemiPos, lCode: Integer;
  lToken, lDecoded: string;
begin
  Result := AValue;
  // strip CDATA wrappers, keep the inner text (titles/descs often arrive in CDATA)
  Result := Result.Replace('<![CDATA[', '', [rfReplaceAll]).Replace(']]>', '', [rfReplaceAll]);
  // numeric character references: &#233;  and hex  &#xE9;  (very common in XMLTV)
  lPos := Pos(cCharRefPrefix, Result);
  while lPos > 0 do
  begin
    lSemiPos := PosEx(';', Result, lPos);
    if lSemiPos = 0 then
      Break;
    lToken := Copy(Result, lPos + Length(cCharRefPrefix),
      lSemiPos - (lPos + Length(cCharRefPrefix))); // chars between "&#" and ";"
    if (lToken <> '') and ((lToken[1] = 'x') or (lToken[1] = 'X')) then
      lCode := StrToIntDef('$' + Copy(lToken, 2, MaxInt), -1)
    else
      lCode := StrToIntDef(lToken, -1);
    // Valid Unicode scalar value? Decode it — BMP to one UTF-16 unit, astral
    // (>$FFFF, e.g. emoji) to a surrogate PAIR via ConvertFromUtf32. Exclude the
    // surrogate range ($D800..$DFFF): emitting a lone surrogate produces an invalid
    // string that can break our own xmltv.php re-serialization / the JSON output.
    lDecoded := '';
    if (lCode > 0) and (lCode <= cUnicodeMax) and
      not ((lCode >= cSurrogateFirst) and (lCode <= cSurrogateLast)) then
      lDecoded := Char.ConvertFromUtf32(lCode);
    if lDecoded <> '' then
    begin
      Result := Copy(Result, 1, lPos - 1) + lDecoded + Copy(Result, lSemiPos + 1, MaxInt);
      lPos := PosEx(cCharRefPrefix, Result, lPos + lDecoded.Length);
    end
    else
      // malformed / lone surrogate — skip past it
      lPos := PosEx(cCharRefPrefix, Result, lPos + Length(cCharRefPrefix));
  end;
  // named entities — &amp; LAST so an already-decoded '&' isn't re-processed
  Result := Result.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"')
             .Replace('&apos;', '''').Replace('&amp;', '&');
end;

function TXmltvEpgReader.Read(const ASource: TSourceConfig;
  const AKeepTvgIds: TArray<string>): TEpgProgrammeList;
var
  lUrl, lXml, lBlock, lChannel, lWanted: string;
  lKeep: TDictionary<string, string>; // lower-case id -> the id as the list spells it
  lKeepAll: Boolean;
  lId: string;
  lStart, lEnd, lCursor, lTagEnd: Integer;
  lProg: TEpgProgramme;
begin
  Result := TEpgProgrammeList.Create(True);
  lUrl := ResolveUrl(ASource);
  if lUrl = '' then
    Exit;

  lKeep := TDictionary<string, string>.Create;
  try
    try
      for lId in AKeepTvgIds do
        if lId <> '' then
          lKeep.AddOrSetValue(LowerCase(lId), lId);
      lKeepAll := lKeep.Count = 0;

      // hybrid fetch (http via Indy / https via OS TLS) + per-provider UA;
      // EPG is a bulk download → long timeout, charset-detecting decode
      lXml := HttpGetText(lUrl, ASource.UserAgent, TimeoutBulkMs, ASource.Referer);

      lCursor := 1;
      repeat
        lStart := PosEx(cTagProgrammeOpen, lXml, lCursor);
        if lStart = 0 then
          Break;
        // a self-closing <programme .../> (no title, nothing to keep): skip it, else
        // the search for </programme> would swallow the NEXT programme into it
        lTagEnd := PosEx('>', lXml, lStart);
        if lTagEnd = 0 then
          Break;
        if lXml[lTagEnd - 1] = '/' then
        begin
          lCursor := lTagEnd + 1;
          Continue;
        end;
        lEnd := PosEx(cTagProgrammeClose, lXml, lStart);
        if lEnd = 0 then
          Break;
        lCursor := lEnd + Length(cTagProgrammeClose);

        // read the channel id WITHOUT copying the block; only materialise the block
        // for programmes we actually keep (most are discarded for unlisted channels)
        // decoded: an id like "Sky&amp;Co.uk" is "Sky&Co.uk" on the M3U side
        lChannel := XmlDecode(AttrValIn(lXml, cAttrChannel, lStart, lEnd));
        if lKeepAll or lKeep.TryGetValue(LowerCase(lChannel), lWanted) then
        begin
          // stored under the list's spelling: matching is case-insensitive, but the
          // guide is served by exact id (npo1.nl in the guide, NPO1.nl on the list)
          if not lKeepAll then
            lChannel := lWanted;
          lBlock := Copy(lXml, lStart, lEnd - lStart);
          lProg := TEpgProgramme.Create;
          lProg.SourceId := ASource.Id;
          lProg.ChannelTvgId := lChannel;
          lProg.StartUtc := ParseXmltvTime(AttrVal(lBlock, cAttrStart));
          lProg.StopUtc := ParseXmltvTime(AttrVal(lBlock, cAttrStop));
          // ParseXmltvTime returns 0 on an unparseable timestamp; skip such a
          // programme rather than storing it pinned to 1899-12-30 (the comment in
          // ParseXmltvTime promises the caller skips — this is where).
          if lProg.StartUtc = 0 then
            FreeAndNil(lProg)
          else
          begin
            lProg.Title := XmlDecode(TagText(lBlock, cTagTitle));
            lProg.Description := XmlDecode(TagText(lBlock, cTagDesc));
            Result.Add(lProg);
          end;
        end;
      until False;
      FillMissingStops(Result);
    except
      Result.Free; // a failed download / parse must not leak what was read so far
      raise;
    end;
  finally
    FreeAndNil(lKeep);
  end;
end;

procedure FillMissingStops(AList: TEpgProgrammeList);
var
  lOpen: TDictionary<string, TEpgProgramme>; // channel -> programme waiting for a stop
  lProg, lPrev: TEpgProgramme;
begin
  lOpen := TDictionary<string, TEpgProgramme>.Create;
  try
    for lProg in AList do
    begin
      if lOpen.TryGetValue(lProg.ChannelTvgId, lPrev) and (lProg.StartUtc > lPrev.StartUtc) then
      begin
        lPrev.StopUtc := lProg.StartUtc;
        lOpen.Remove(lProg.ChannelTvgId);
      end;
      if lProg.StopUtc = 0 then
        lOpen.AddOrSetValue(lProg.ChannelTvgId, lProg);
    end;
    for lProg in lOpen.Values do
      lProg.StopUtc := IncHour(lProg.StartUtc, cDefaultLastProgrammeHours);
  finally
    FreeAndNil(lOpen);
  end;
end;

function ReadExtraXmltv(const AUrl: string; ASourceId: Integer;
  out AChannels: TArray<TEpgChannelInfo>;
  const AKeepChannel: TFunc<TEpgChannelInfo, Boolean>): TEpgProgrammeList;
var
  lXml, lBlock, lChannel: string;
  lStart, lEnd, lCursor, lTagEnd: Integer;
  lInfo: TEpgChannelInfo;
  lProg: TEpgProgramme;
  lParser: TXmltvEpgReader;
  lKeep: TDictionary<string, Byte>; // raw channel ids whose programmes we keep
  lChans: TList<TEpgChannelInfo>;   // appending to an array was quadratic (40k channels)
begin
  AChannels := nil;
  Result := TEpgProgrammeList.Create(True);
  lKeep := nil;
  lChans := nil;
  lParser := nil;
  try
    lKeep := TDictionary<string, Byte>.Create;
    lChans := TList<TEpgChannelInfo>.Create;
    lParser := TXmltvEpgReader.Create; // only for ParseXmltvTime (no interface ref taken)
    try
      lXml := HttpGetText(AUrl, '', TimeoutBulkMs, ''); // gunzips .gz transparently
      // channels: <channel id="NPO.1.nl"><display-name lang="nl">NPO 1</display-name>…
      lCursor := 1;
      repeat
        lStart := PosEx(cTagChannelOpen, lXml, lCursor);
        if lStart = 0 then
          Break;
        // "<channel" must be the tag, not the start of an attribute name
        if (lStart + Length(cTagChannelOpen) <= Length(lXml)) and
           not CharInSet(lXml[lStart + Length(cTagChannelOpen)], [' ', '>', #9, #10, #13]) then
        begin
          lCursor := lStart + 1;
          Continue;
        end;
        lEnd := PosEx(cTagChannelClose, lXml, lStart);
        if lEnd = 0 then
          Break;
        lBlock := Copy(lXml, lStart, lEnd - lStart);
        lCursor := lEnd + Length(cTagChannelClose);
        lInfo.Id := XmlDecode(AttrVal(lBlock, cAttrId));
        lInfo.Name := XmlDecode(TagText(lBlock, cTagDisplayName));
        if lInfo.Id <> '' then
        begin
          lChans.Add(lInfo);
          if not Assigned(AKeepChannel) or AKeepChannel(lInfo) then
            lKeep.AddOrSetValue(lInfo.Id, 0);
        end;
      until False;

      lCursor := 1;
      repeat
        lStart := PosEx(cTagProgrammeOpen, lXml, lCursor);
        if lStart = 0 then
          Break;
        // a self-closing <programme .../> (no title, nothing to keep): skip it, else
        // the search for </programme> would swallow the NEXT programme into it
        lTagEnd := PosEx('>', lXml, lStart);
        if lTagEnd = 0 then
          Break;
        if lXml[lTagEnd - 1] = '/' then
        begin
          lCursor := lTagEnd + 1;
          Continue;
        end;
        lEnd := PosEx(cTagProgrammeClose, lXml, lStart);
        if lEnd = 0 then
          Break;
        lCursor := lEnd + Length(cTagProgrammeClose);
        // skip unwanted channels without copying their block
        lChannel := XmlDecode(AttrValIn(lXml, cAttrChannel, lStart, lEnd));
        if not lKeep.ContainsKey(lChannel) then
          Continue;
        lBlock := Copy(lXml, lStart, lEnd - lStart);
        lProg := TEpgProgramme.Create;
        lProg.SourceId := ASourceId;
        lProg.ChannelTvgId := EXTRA_EPG_PREFIX + lChannel;
        lProg.StartUtc := lParser.ParseXmltvTime(AttrVal(lBlock, cAttrStart));
        lProg.StopUtc := lParser.ParseXmltvTime(AttrVal(lBlock, cAttrStop));
        if lProg.StartUtc = 0 then
          FreeAndNil(lProg)
        else
        begin
          lProg.Title := XmlDecode(TagText(lBlock, cTagTitle));
          lProg.Description := XmlDecode(TagText(lBlock, cTagDesc));
          Result.Add(lProg);
        end;
      until False;
      FillMissingStops(Result);
      AChannels := lChans.ToArray;
    except
      Result.Free;
      raise;
    end;
  finally
    FreeAndNil(lParser);
    FreeAndNil(lKeep);
    FreeAndNil(lChans);
  end;
end;

end.
