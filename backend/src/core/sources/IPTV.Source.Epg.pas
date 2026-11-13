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
  System.SysUtils,
  IPTV.Model.Source, IPTV.Model.Epg, IPTV.Source.Intf;

type
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
  System.Classes, System.DateUtils, System.StrUtils, System.Math,
  System.Character, System.Generics.Collections,
  System.Net.HttpClient, System.NetEncoding,
  IPTV.Model.Types, IPTV.Source.Http;

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
  Parts: TArray<string>;
  P: string;
begin
  Result := AValue.Trim;
  Parts := AValue.Split([',']);
  for P in Parts do
    if P.Trim <> '' then
      Exit(P.Trim);
end;

function TXmltvEpgReader.ParseXmltvTime(const AValue: string): TDateTime;
const
  cXmltvMinDigits = 12; // YYYYMMDDHHMM (seconds optional)
  cXmltvFullDigits = 14; // YYYYMMDDHHMMSS
var
  S, Digits, TzPart: string;
  Y, Mo, D, H, Mi, Se: Word;
  OffSign, OffH, OffM, N: Integer;
  Local: TDateTime;
begin
  // "YYYYMMDDHHMM[SS] [±HH[[:]MM]]" -> UTC. The zone may follow without a space
  // ("20261113120000+0100") and may be hours only ("+01").
  S := AValue.Trim;
  N := 0;
  while (N < S.Length) and CharInSet(S.Chars[N], ['0'..'9']) do
    Inc(N);
  Digits := S.Substring(0, N);
  // accept both "±HHMM" and the colon form "±HH:MM" (half-hour zones keep minutes)
  TzPart := S.Substring(N).Trim.Replace(':', '');
  if Digits.Length < cXmltvMinDigits then
    Exit(0);
  Y := StrToIntDef(Digits.Substring(0, 4), 0);
  Mo := StrToIntDef(Digits.Substring(4, 2), 1);
  D := StrToIntDef(Digits.Substring(6, 2), 1);
  H := StrToIntDef(Digits.Substring(8, 2), 0);
  Mi := StrToIntDef(Digits.Substring(10, 2), 0);
  if Digits.Length >= cXmltvFullDigits then
    Se := StrToIntDef(Digits.Substring(12, 2), 0)
  else
    Se := 0;
  // a single malformed timestamp (e.g. month 13) must NOT abort the whole EPG
  // read — return 0 and let the caller skip just this value
  if not TryEncodeDateTime(Y, Mo, D, H, Mi, Se, 0, Local) then
    Exit(0);
  Result := Local;
  if (TzPart.Length >= cTzHoursLen) and CharInSet(TzPart.Chars[0], ['+', '-']) then
  begin
    if TzPart.Chars[0] = '-' then OffSign := 1 else OffSign := -1; // to UTC
    OffH := StrToIntDef(TzPart.Substring(1, 2), 0);
    OffM := 0;
    if TzPart.Length >= cTzFullLen then
      OffM := StrToIntDef(TzPart.Substring(3, 2), 0);
    Result := IncMinute(Local, OffSign * (OffH * MinsPerHour + OffM));
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
  P, L, Last: Integer;
  Q: Char;
begin
  // walk ONLY the window [AFrom, ATo): a PosEx for a needle that isn't in this
  // block would scan to the end of a 100+ MB guide - per programme
  L := Length(AName);
  Last := Min(ATo, Length(AXml) + 1) - L - 2; // room for name + '=' + quote
  P := Max(AFrom, 1);
  while P <= Last do
  begin
    if (AXml[P] = AName[1]) and (AXml[P + L] = '=') and
       ((P = 1) or CharInSet(AXml[P - 1], [' ', #9, #10, #13, '<'])) and
       CompareMem(@AXml[P], @AName[1], L * SizeOf(Char)) then
    begin
      Q := AXml[P + L + 1];
      if (Q = '"') or (Q = '''') then
      begin
        AQuote := Q;
        Exit(P + L + 2);
      end;
    end;
    Inc(P);
  end;
  AQuote := '"';
  Result := 0;
end;

function AttrVal(const ABlock, AName: string): string;
var
  P, E: Integer;
  Q: Char;
begin
  Result := '';
  P := FindAttrValueStart(ABlock, AName, 1, Length(ABlock) + 1, Q);
  if P = 0 then
    Exit;
  E := PosEx(Q, ABlock, P);
  if E > 0 then
    Result := Copy(ABlock, P, E - P);
end;

// Read an attribute IN PLACE from a window [AFrom, ATo) of the big XML string,
// without first copying the whole block. Used for the channel filter so we only
// allocate a per-programme substring for the channels we actually keep — a full
// provider guide has hundreds of thousands of <programme>s we discard, and
// copying each one just to read 'channel' was the main allocation churn (and the
// memory the manager held onto after a refresh).
function AttrValIn(const AXml, AName: string; AFrom, ATo: Integer): string;
var
  P, E: Integer;
  Q: Char;
begin
  Result := '';
  P := FindAttrValueStart(AXml, AName, AFrom, ATo, Q);
  if P = 0 then
    Exit;
  E := PosEx(Q, AXml, P);
  if (E > 0) and (E <= ATo) then
    Result := Copy(AXml, P, E - P);
end;

function TagText(const ABlock, ATag: string): string;
var
  POpen, PGt, PClose: Integer;
begin
  Result := '';
  POpen := Pos('<' + ATag, ABlock);
  if POpen = 0 then
    Exit;
  PGt := PosEx('>', ABlock, POpen);
  if PGt = 0 then
    Exit;
  PClose := PosEx('</' + ATag + '>', ABlock, PGt);
  if PClose = 0 then
    Exit;
  Result := Copy(ABlock, PGt + 1, PClose - PGt - 1);
end;

function XmlDecode(const S: string): string;
var
  P, SemiPos, Code: Integer;
  Token, Decoded: string;
begin
  Result := S;
  // strip CDATA wrappers, keep the inner text (titles/descs often arrive in CDATA)
  Result := Result.Replace('<![CDATA[', '', [rfReplaceAll]).Replace(']]>', '', [rfReplaceAll]);
  // numeric character references: &#233;  and hex  &#xE9;  (very common in XMLTV)
  P := Pos(cCharRefPrefix, Result);
  while P > 0 do
  begin
    SemiPos := PosEx(';', Result, P);
    if SemiPos = 0 then
      Break;
    Token := Copy(Result, P + Length(cCharRefPrefix),
      SemiPos - (P + Length(cCharRefPrefix))); // chars between "&#" and ";"
    if (Token <> '') and ((Token[1] = 'x') or (Token[1] = 'X')) then
      Code := StrToIntDef('$' + Copy(Token, 2, MaxInt), -1)
    else
      Code := StrToIntDef(Token, -1);
    // Valid Unicode scalar value? Decode it — BMP to one UTF-16 unit, astral
    // (>$FFFF, e.g. emoji) to a surrogate PAIR via ConvertFromUtf32. Exclude the
    // surrogate range ($D800..$DFFF): emitting a lone surrogate produces an invalid
    // string that can break our own xmltv.php re-serialization / the JSON output.
    Decoded := '';
    if (Code > 0) and (Code <= cUnicodeMax) and
      not ((Code >= cSurrogateFirst) and (Code <= cSurrogateLast)) then
      Decoded := Char.ConvertFromUtf32(Code);
    if Decoded <> '' then
    begin
      Result := Copy(Result, 1, P - 1) + Decoded + Copy(Result, SemiPos + 1, MaxInt);
      P := PosEx(cCharRefPrefix, Result, P + Decoded.Length);
    end
    else
      P := PosEx(cCharRefPrefix, Result, P + Length(cCharRefPrefix)); // malformed / lone surrogate — skip past it
  end;
  // named entities — &amp; LAST so an already-decoded '&' isn't re-processed
  Result := Result.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"')
             .Replace('&apos;', '''').Replace('&amp;', '&');
end;

function TXmltvEpgReader.Read(const ASource: TSourceConfig; const AKeepTvgIds: TArray<string>): TEpgProgrammeList;
var
  Url, Xml, Block, Channel, lWanted: string;
  Keep: TDictionary<string, string>; // lower-case id -> the id as the list spells it
  KeepAll: Boolean;
  T: string;
  PStart, PEnd, Cursor: Integer;
  Prog: TEpgProgramme;
begin
  Result := TEpgProgrammeList.Create(True);
  Url := ResolveUrl(ASource);
  if Url = '' then
    Exit;

  Keep := TDictionary<string, string>.Create;
  try
  try
    for T in AKeepTvgIds do
      if T <> '' then
        Keep.AddOrSetValue(LowerCase(T), T);
    KeepAll := Keep.Count = 0;

    // hybrid fetch (http via Indy / https via OS TLS) + per-provider UA;
    // EPG is a bulk download → long timeout, charset-detecting decode
    Xml := HttpGetText(Url, ASource.UserAgent, TimeoutBulkMs, ASource.Referer);

    Cursor := 1;
    repeat
      PStart := PosEx(cTagProgrammeOpen, Xml, Cursor);
      if PStart = 0 then
        Break;
      PEnd := PosEx(cTagProgrammeClose, Xml, PStart);
      if PEnd = 0 then
        Break;
      Cursor := PEnd + Length(cTagProgrammeClose);

      // read the channel id WITHOUT copying the block; only materialise the block
      // for programmes we actually keep (most are discarded for unlisted channels)
      // decoded: an id like "Sky&amp;Co.uk" is "Sky&Co.uk" on the M3U side
      Channel := XmlDecode(AttrValIn(Xml, cAttrChannel, PStart, PEnd));
      if KeepAll or Keep.TryGetValue(LowerCase(Channel), lWanted) then
      begin
        // stored under the list's spelling: matching is case-insensitive, but the
        // guide is served by exact id (npo1.nl in the guide, NPO1.nl on the list)
        if not KeepAll then
          Channel := lWanted;
        Block := Copy(Xml, PStart, PEnd - PStart);
        Prog := TEpgProgramme.Create;
        Prog.SourceId := ASource.Id;
        Prog.ChannelTvgId := Channel;
        Prog.StartUtc := ParseXmltvTime(AttrVal(Block, cAttrStart));
        Prog.StopUtc := ParseXmltvTime(AttrVal(Block, cAttrStop));
        // ParseXmltvTime returns 0 on an unparseable timestamp; skip such a
        // programme rather than storing it pinned to 1899-12-30 (the comment in
        // ParseXmltvTime promises the caller skips — this is where).
        if Prog.StartUtc = 0 then
          Prog.Free
        else
        begin
          Prog.Title := XmlDecode(TagText(Block, cTagTitle));
          Prog.Description := XmlDecode(TagText(Block, cTagDesc));
          Result.Add(Prog);
        end;
      end;
    until False;
    FillMissingStops(Result);
  except
    Result.Free; // a failed download / parse must not leak what was read so far
    raise;
  end;
  finally
    Keep.Free;
  end;
end;

procedure FillMissingStops(AList: TEpgProgrammeList);
var
  Open: TDictionary<string, TEpgProgramme>; // channel -> programme waiting for a stop
  P, Prev: TEpgProgramme;
begin
  Open := TDictionary<string, TEpgProgramme>.Create;
  try
    for P in AList do
    begin
      if Open.TryGetValue(P.ChannelTvgId, Prev) and (P.StartUtc > Prev.StartUtc) then
      begin
        Prev.StopUtc := P.StartUtc;
        Open.Remove(P.ChannelTvgId);
      end;
      if P.StopUtc = 0 then
        Open.AddOrSetValue(P.ChannelTvgId, P);
    end;
    for P in Open.Values do
      P.StopUtc := IncHour(P.StartUtc, cDefaultLastProgrammeHours);
  finally
    Open.Free;
  end;
end;

function ReadExtraXmltv(const AUrl: string; ASourceId: Integer;
  out AChannels: TArray<TEpgChannelInfo>;
  const AKeepChannel: TFunc<TEpgChannelInfo, Boolean>): TEpgProgrammeList;
var
  Xml, Block, Channel: string;
  PStart, PEnd, Cursor: Integer;
  Info: TEpgChannelInfo;
  Prog: TEpgProgramme;
  Parser: TXmltvEpgReader;
  Keep: TDictionary<string, Byte>; // raw channel ids whose programmes we keep
  lChans: TList<TEpgChannelInfo>;   // appending to an array was quadratic (40k channels)
begin
  AChannels := nil;
  Result := TEpgProgrammeList.Create(True);
  Keep := TDictionary<string, Byte>.Create;
  lChans := TList<TEpgChannelInfo>.Create;
  Parser := TXmltvEpgReader.Create; // only for ParseXmltvTime (no interface ref taken)
  try
  try
    Xml := HttpGetText(AUrl, '', TimeoutBulkMs, ''); // gunzips .gz transparently
    // channels: <channel id="NPO.1.nl"><display-name lang="nl">NPO 1</display-name>…
    Cursor := 1;
    repeat
      PStart := PosEx(cTagChannelOpen, Xml, Cursor);
      if PStart = 0 then
        Break;
      // "<channel" must be the tag, not the start of an attribute name
      if (PStart + Length(cTagChannelOpen) <= Length(Xml)) and
         not CharInSet(Xml[PStart + Length(cTagChannelOpen)], [' ', '>', #9, #10, #13]) then
      begin
        Cursor := PStart + 1;
        Continue;
      end;
      PEnd := PosEx(cTagChannelClose, Xml, PStart);
      if PEnd = 0 then
        Break;
      Block := Copy(Xml, PStart, PEnd - PStart);
      Cursor := PEnd + Length(cTagChannelClose);
      Info.Id := XmlDecode(AttrVal(Block, cAttrId));
      Info.Name := XmlDecode(TagText(Block, cTagDisplayName));
      if Info.Id <> '' then
      begin
        lChans.Add(Info);
        if not Assigned(AKeepChannel) or AKeepChannel(Info) then
          Keep.AddOrSetValue(Info.Id, 0);
      end;
    until False;

    Cursor := 1;
    repeat
      PStart := PosEx(cTagProgrammeOpen, Xml, Cursor);
      if PStart = 0 then
        Break;
      PEnd := PosEx(cTagProgrammeClose, Xml, PStart);
      if PEnd = 0 then
        Break;
      Cursor := PEnd + Length(cTagProgrammeClose);
      // skip unwanted channels without copying their block
      Channel := XmlDecode(AttrValIn(Xml, cAttrChannel, PStart, PEnd));
      if not Keep.ContainsKey(Channel) then
        Continue;
      Block := Copy(Xml, PStart, PEnd - PStart);
      Prog := TEpgProgramme.Create;
      Prog.SourceId := ASourceId;
      Prog.ChannelTvgId := EXTRA_EPG_PREFIX + Channel;
      Prog.StartUtc := Parser.ParseXmltvTime(AttrVal(Block, cAttrStart));
      Prog.StopUtc := Parser.ParseXmltvTime(AttrVal(Block, cAttrStop));
      if Prog.StartUtc = 0 then
        Prog.Free
      else
      begin
        Prog.Title := XmlDecode(TagText(Block, cTagTitle));
        Prog.Description := XmlDecode(TagText(Block, cTagDesc));
        Result.Add(Prog);
      end;
    until False;
    FillMissingStops(Result);
    AChannels := lChans.ToArray;
  except
    Result.Free;
    raise;
  end;
  finally
    Parser.Free;
    Keep.Free;
    lChans.Free;
  end;
end;

end.
