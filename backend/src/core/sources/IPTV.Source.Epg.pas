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
function ReadExtraXmltv(const AUrl: string; ASourceId: Integer;
  out AChannels: TArray<TEpgChannelInfo>): TEpgProgrammeList;

implementation

uses
  System.SysUtils, System.Classes, System.DateUtils, System.StrUtils,
  System.Character, System.Generics.Collections,
  System.Net.HttpClient, System.NetEncoding,
  IPTV.Model.Types, IPTV.Source.Http;

function TXmltvEpgReader.ResolveUrl(const ASource: TSourceConfig): string;
begin
  if ASource.EpgUrl <> '' then
    Exit(ASource.EpgUrl);
  if ASource.Kind = skXtream then
    Result := Format('%s/xmltv.php?username=%s&password=%s',
      [ASource.Url.TrimRight(['/']),
       TNetEncoding.URL.Encode(ASource.Username),
       TNetEncoding.URL.Encode(ASource.Password)])
  else
    Result := '';
end;

function TXmltvEpgReader.ParseXmltvTime(const AValue: string): TDateTime;
var
  S, TzPart: string;
  Y, Mo, D, H, Mi, Se: Word;
  OffSign, OffH, OffM, SpacePos: Integer;
  Local: TDateTime;
begin
  // "YYYYMMDDHHMMSS +HHMM" -> UTC
  S := AValue.Trim;
  SpacePos := S.IndexOf(' ');
  TzPart := '';
  if SpacePos > 0 then
  begin
    // accept both the standard "±HHMM" and the colon form "±HH:MM" (some panels
    // emit it) — strip the colon so half-hour zones (e.g. +05:30) keep their minutes.
    TzPart := S.Substring(SpacePos + 1).Trim.Replace(':', '');
    S := S.Substring(0, SpacePos);
  end;
  if S.Length < 14 then
    Exit(0);
  Y := StrToIntDef(S.Substring(0, 4), 0);
  Mo := StrToIntDef(S.Substring(4, 2), 1);
  D := StrToIntDef(S.Substring(6, 2), 1);
  H := StrToIntDef(S.Substring(8, 2), 0);
  Mi := StrToIntDef(S.Substring(10, 2), 0);
  Se := StrToIntDef(S.Substring(12, 2), 0);
  // a single malformed timestamp (e.g. month 13) must NOT abort the whole EPG
  // read — return 0 and let the caller skip just this value
  if not TryEncodeDateTime(Y, Mo, D, H, Mi, Se, 0, Local) then
    Exit(0);
  Result := Local;
  if TzPart.Length >= 5 then
  begin
    if TzPart[Low(string)] = '-' then OffSign := 1 else OffSign := -1; // to UTC
    OffH := StrToIntDef(TzPart.Substring(1, 2), 0);
    OffM := StrToIntDef(TzPart.Substring(3, 2), 0);
    Result := IncMinute(Local, OffSign * (OffH * 60 + OffM));
  end;
end;

// minimal XML helpers (no DOM)

// Find `AName="` within AXml in the window [AFrom, ATo), but ONLY at a real
// attribute boundary — the char before it must be whitespace or '<'. Without this
// a bare substring search makes 'start' match inside 'vps-start="..."' /
// 'pdc-start="..."' (both valid XMLTV <programme> attributes) and read the wrong
// value. Returns the position just AFTER the opening quote, or 0 if not found.
function FindAttrValueStart(const AXml, AName: string; AFrom, ATo: Integer): Integer;
var
  Needle: string;
  P: Integer;
begin
  Needle := AName + '="';
  P := PosEx(Needle, AXml, AFrom);
  while (P > 0) and (P < ATo) do
  begin
    if (P = 1) or CharInSet(AXml[P - 1], [' ', #9, #10, #13, '<']) then
      Exit(P + Length(Needle));
    P := PosEx(Needle, AXml, P + 1);
  end;
  Result := 0;
end;

function AttrVal(const ABlock, AName: string): string;
var
  P, E: Integer;
begin
  Result := '';
  P := FindAttrValueStart(ABlock, AName, 1, Length(ABlock) + 1);
  if P = 0 then
    Exit;
  E := PosEx('"', ABlock, P);
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
begin
  Result := '';
  P := FindAttrValueStart(AXml, AName, AFrom, ATo);
  if P = 0 then
    Exit;
  E := PosEx('"', AXml, P);
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
  P := Pos('&#', Result);
  while P > 0 do
  begin
    SemiPos := PosEx(';', Result, P);
    if SemiPos = 0 then
      Break;
    Token := Copy(Result, P + 2, SemiPos - (P + 2)); // chars between "&#" and ";"
    if (Token <> '') and ((Token[1] = 'x') or (Token[1] = 'X')) then
      Code := StrToIntDef('$' + Copy(Token, 2, MaxInt), -1)
    else
      Code := StrToIntDef(Token, -1);
    // Valid Unicode scalar value? Decode it — BMP to one UTF-16 unit, astral
    // (>$FFFF, e.g. emoji) to a surrogate PAIR via ConvertFromUtf32. Exclude the
    // surrogate range ($D800..$DFFF): emitting a lone surrogate produces an invalid
    // string that can break our own xmltv.php re-serialization / the JSON output.
    Decoded := '';
    if (Code > 0) and (Code <= $10FFFF) and not ((Code >= $D800) and (Code <= $DFFF)) then
      Decoded := Char.ConvertFromUtf32(Code);
    if Decoded <> '' then
    begin
      Result := Copy(Result, 1, P - 1) + Decoded + Copy(Result, SemiPos + 1, MaxInt);
      P := PosEx('&#', Result, P + Decoded.Length);
    end
    else
      P := PosEx('&#', Result, P + 2); // malformed / lone surrogate — skip past it
  end;
  // named entities — &amp; LAST so an already-decoded '&' isn't re-processed
  Result := Result.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"')
             .Replace('&apos;', '''').Replace('&amp;', '&');
end;

function TXmltvEpgReader.Read(const ASource: TSourceConfig; const AKeepTvgIds: TArray<string>): TEpgProgrammeList;
const
  PROG_OPEN = '<programme';
  PROG_CLOSE = '</programme>';
var
  Url, Xml, Block, Channel: string;
  Keep: TDictionary<string, Byte>;
  KeepAll: Boolean;
  T: string;
  PStart, PEnd, Cursor: Integer;
  Prog: TEpgProgramme;
begin
  Result := TEpgProgrammeList.Create(True);
  Url := ResolveUrl(ASource);
  if Url = '' then
    Exit;

  Keep := TDictionary<string, Byte>.Create;
  try
    for T in AKeepTvgIds do
      if T <> '' then
        Keep.AddOrSetValue(LowerCase(T), 0);
    KeepAll := Keep.Count = 0;

    // hybrid fetch (http via Indy / https via OS TLS) + per-provider UA;
    // EPG is a bulk download → long timeout, charset-detecting decode
    Xml := HttpGetText(Url, ASource.UserAgent, TimeoutBulkMs, ASource.Referer);

    Cursor := 1;
    repeat
      PStart := PosEx(PROG_OPEN, Xml, Cursor);
      if PStart = 0 then
        Break;
      PEnd := PosEx(PROG_CLOSE, Xml, PStart);
      if PEnd = 0 then
        Break;
      Cursor := PEnd + Length(PROG_CLOSE);

      // read the channel id WITHOUT copying the block; only materialise the block
      // for programmes we actually keep (most are discarded for unlisted channels)
      Channel := AttrValIn(Xml, 'channel', PStart, PEnd);
      if KeepAll or Keep.ContainsKey(LowerCase(Channel)) then
      begin
        Block := Copy(Xml, PStart, PEnd - PStart);
        Prog := TEpgProgramme.Create;
        Prog.SourceId := ASource.Id;
        Prog.ChannelTvgId := Channel;
        Prog.StartUtc := ParseXmltvTime(AttrVal(Block, 'start'));
        Prog.StopUtc := ParseXmltvTime(AttrVal(Block, 'stop'));
        // ParseXmltvTime returns 0 on an unparseable timestamp; skip such a
        // programme rather than storing it pinned to 1899-12-30 (the comment in
        // ParseXmltvTime promises the caller skips — this is where).
        if Prog.StartUtc = 0 then
          Prog.Free
        else
        begin
          Prog.Title := XmlDecode(TagText(Block, 'title'));
          Prog.Description := XmlDecode(TagText(Block, 'desc'));
          Result.Add(Prog);
        end;
      end;
    until False;
  finally
    Keep.Free;
  end;
end;

function ReadExtraXmltv(const AUrl: string; ASourceId: Integer;
  out AChannels: TArray<TEpgChannelInfo>): TEpgProgrammeList;
const
  CH_OPEN = '<channel';
  CH_CLOSE = '</channel>';
  PROG_OPEN = '<programme';
  PROG_CLOSE = '</programme>';
var
  Xml, Block: string;
  PStart, PEnd, Cursor: Integer;
  Info: TEpgChannelInfo;
  Prog: TEpgProgramme;
  Parser: TXmltvEpgReader;
begin
  AChannels := nil;
  Result := TEpgProgrammeList.Create(True);
  Xml := HttpGetText(AUrl, '', TimeoutBulkMs, ''); // gunzips .gz transparently
  Parser := TXmltvEpgReader.Create; // only for ParseXmltvTime (no interface ref taken)
  try
    // channels: <channel id="NPO.1.nl"><display-name lang="nl">NPO 1</display-name>…
    Cursor := 1;
    repeat
      PStart := PosEx(CH_OPEN, Xml, Cursor);
      if PStart = 0 then
        Break;
      // "<channel" must be the tag, not the start of an attribute name
      if (PStart + Length(CH_OPEN) <= Length(Xml)) and
         not CharInSet(Xml[PStart + Length(CH_OPEN)], [' ', '>', #9, #10, #13]) then
      begin
        Cursor := PStart + 1;
        Continue;
      end;
      PEnd := PosEx(CH_CLOSE, Xml, PStart);
      if PEnd = 0 then
        Break;
      Block := Copy(Xml, PStart, PEnd - PStart);
      Cursor := PEnd + Length(CH_CLOSE);
      Info.Id := XmlDecode(AttrVal(Block, 'id'));
      Info.Name := XmlDecode(TagText(Block, 'display-name'));
      if Info.Id <> '' then
        AChannels := AChannels + [Info];
    until False;

    Cursor := 1;
    repeat
      PStart := PosEx(PROG_OPEN, Xml, Cursor);
      if PStart = 0 then
        Break;
      PEnd := PosEx(PROG_CLOSE, Xml, PStart);
      if PEnd = 0 then
        Break;
      Cursor := PEnd + Length(PROG_CLOSE);
      Block := Copy(Xml, PStart, PEnd - PStart);
      Prog := TEpgProgramme.Create;
      Prog.SourceId := ASourceId;
      Prog.ChannelTvgId := EXTRA_EPG_PREFIX + XmlDecode(AttrVal(Block, 'channel'));
      Prog.StartUtc := Parser.ParseXmltvTime(AttrVal(Block, 'start'));
      Prog.StopUtc := Parser.ParseXmltvTime(AttrVal(Block, 'stop'));
      if Prog.StartUtc = 0 then
        Prog.Free
      else
      begin
        Prog.Title := XmlDecode(TagText(Block, 'title'));
        Prog.Description := XmlDecode(TagText(Block, 'desc'));
        Result.Add(Prog);
      end;
    until False;
  finally
    Parser.Free;
  end;
end;

end.
