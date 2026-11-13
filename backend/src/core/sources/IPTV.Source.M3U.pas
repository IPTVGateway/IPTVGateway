unit IPTV.Source.M3U;

{ Reads plain M3U and extended M3U_plus playlists.

  M3U_plus lines carry attributes:
    #EXTINF:-1 tvg-id="x" tvg-name="X" tvg-logo="..." group-title="...",Display
    http://provider/stream.ts
  Plain M3U lines have no attributes:
    #EXTINF:-1,Display
    http://provider/stream.ts

  Both are handled by the same parser — absent attributes simply read as ''.
  Content type is inferred from the URL/group (very rough heuristic) and may be
  refined later; for M3U everything defaults to Live unless it looks like VOD. }

interface

uses
  IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Source.Intf;

type
  TM3UReader = class(TInterfacedObject, ISourceReader)
  private
    function GetAttr(const ALine, AName: string): string;
    function GuessContentType(const AGroup, AUrl: string): Integer;
  public
    /// Pure parser: M3U text in, snapshot populated. Public so tests can drive it.
    /// AUser/APass are the provider credentials (from the source fields or the
    /// playlist URL) — passed so each stream's upstream_id is derived WITHOUT the
    /// credentials, so it survives a new subscription at the same provider.
    procedure ParseContent(const AContent: string; ASnapshot: TSourceSnapshot;
      const AUser: string = ''; const APass: string = '');
    function Read(const ASource: TSourceConfig): TSourceSnapshot;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.RegularExpressions,
  System.Net.HttpClient, System.IOUtils,
  IPTV.Model.Types, IPTV.Source.Http, IPTV.Core.Utils;

const
  // M3U directives
  cM3uHeader = '#EXTM3U';
  cM3uExtInf = '#EXTINF';
  cM3uDirectivePrefix = '#';

  // M3U_plus attributes
  cAttrUrlTvg = 'url-tvg';
  cAttrXTvgUrl = 'x-tvg-url';
  cAttrTvgId = 'tvg-id';
  cAttrTvgName = 'tvg-name';
  cAttrTvgLogo = 'tvg-logo';
  cAttrGroupTitle = 'group-title';

  // Xtream-style URL path segments that reveal the content type
  cUrlPathMovie = '/movie/';
  cUrlPathSeries = '/series/';
  cUrlPathLive = '/live/';

  // a playlist "URL" starting with this is fetched; anything else is a local file
  cSchemeHttp = 'http';

  // get.php query parameters carrying the credentials
  cQueryUsername = 'username';
  cQueryPassword = 'password';

  cIgnoreCase = True;                  // string.StartsWith AIgnoreCase

{ TM3UReader }

function TM3UReader.GetAttr(const ALine, AName: string): string;
var
  M: TMatch;
begin
  // attribute form:  name="value"  — the (?<![\w-]) boundary stops 'tvg-id' from
  // matching inside 'catchup-tvg-id'/'parent-tvg-id' etc.
  M := TRegEx.Match(ALine, '(?<![\w-])' + AName + '="([^"]*)"', [roIgnoreCase]);
  if M.Success then
    Result := M.Groups[1].Value
  else
    Result := '';
end;

function TM3UReader.GuessContentType(const AGroup, AUrl: string): Integer;
var
  G, U: string;
begin
  G := AGroup.ToLower;
  U := AUrl.ToLower;
  // the Xtream-style URL path is the most reliable hint: a live group called
  // "NL| FILM" or "VODAFONE SPORT" must stay live
  if U.Contains(cUrlPathMovie) then
    Exit(Ord(ctMovie));
  if U.Contains(cUrlPathSeries) then
    Exit(Ord(ctSeries));
  if TRegEx.IsMatch(G, '(^|[^a-z])radio([^a-z]|$)') then
    Exit(Ord(ctRadio));
  if U.Contains(cUrlPathLive) then
    Exit(Ord(ctLive));
  // otherwise whole words in the group name only
  if TRegEx.IsMatch(G, '(^|[^a-z])(vod|films?|movies?)([^a-z]|$)') then
    Exit(Ord(ctMovie));
  if TRegEx.IsMatch(G, '(^|[^a-z])(series?|tv shows?)([^a-z]|$)') then
    Exit(Ord(ctSeries));
  Result := Ord(ctLive);
end;

procedure TM3UReader.ParseContent(const AContent: string; ASnapshot: TSourceSnapshot;
  const AUser: string = ''; const APass: string = '');
var
  Lines: TArray<string>;
  I, CommaPos: Integer;
  Trimmed: string;
  Item: TStreamItem;
begin
  Item := nil;
  Lines := AContent.Replace(#13#10, #10).Replace(#13, #10).Split([#10]);
  for I := 0 to High(Lines) do
  try
    Trimmed := Lines[I].Trim;
    if Trimmed = '' then
      Continue;
    if Trimmed.StartsWith(cM3uHeader) then
    begin
      // header may carry the XMLTV guide url: #EXTM3U url-tvg="..." x-tvg-url="..."
      ASnapshot.EpgUrl := GetAttr(Trimmed, cAttrUrlTvg);
      if ASnapshot.EpgUrl = '' then
        ASnapshot.EpgUrl := GetAttr(Trimmed, cAttrXTvgUrl);
      Continue;
    end;

    if Trimmed.StartsWith(cM3uExtInf, cIgnoreCase) then
    begin
      Item := TStreamItem.Create;
      Item.SourceId := ASnapshot.SourceId;
      ASnapshot.Streams.Add(Item); // own immediately so a malformed line can't leak it
      Item.TvgId := GetAttr(Trimmed, cAttrTvgId);
      Item.TvgName := GetAttr(Trimmed, cAttrTvgName);
      Item.Logo := GetAttr(Trimmed, cAttrTvgLogo);
      Item.GroupTitle := GetAttr(Trimmed, cAttrGroupTitle);
      Item.CategoryUpstreamId := Item.GroupTitle;
      // display name is everything after the FIRST comma that is OUTSIDE quotes —
      // attribute values like group-title="News, Sports" contain commas that must
      // be skipped, and the title itself may contain commas ("Movie, The")
      CommaPos := -1;
      var InQuote := False;
      for var K := 0 to Trimmed.Length - 1 do
        if Trimmed.Chars[K] = '"' then
          InQuote := not InQuote
        else if (Trimmed.Chars[K] = ',') and not InQuote then
        begin
          CommaPos := K;
          Break;
        end;
      if CommaPos >= 0 then
        Item.Name := Trimmed.Substring(CommaPos + 1).Trim;
    end
    else if Trimmed.StartsWith(cM3uDirectivePrefix) then
      // other directives (#EXTGRP, #EXTVLCOPT, ...) ignored for now
      Continue
    else if Assigned(Item) and (Item.UpstreamUrl = '') then
    begin
      Item.UpstreamUrl := Trimmed;
      Item.ContentType := TContentType(GuessContentType(Item.GroupTitle, Trimmed));
      // M3U has no stable id; derive one from the URL (with the credentials blanked
      // out) so it stays constant across a new subscription at the same provider.
      Item.UpstreamId := M3uStreamId(Trimmed, AUser, APass);
      Item := nil;
    end;
  except
    // tolerate a malformed line — log-and-skip rather than abort the playlist (#16)
    Continue;
  end;

  // Drop any #EXTINF that never received a URL line (it was the last line, was
  // followed by another #EXTINF, or its "URL" started with '#'). Such ghost items
  // have an empty upstream_url AND empty upstream_id, which would collide on the
  // (source, type, upstream_id) merge key and persist a dead, non-playable row.
  for I := ASnapshot.Streams.Count - 1 downto 0 do
    if ASnapshot.Streams[I].UpstreamUrl = '' then
      ASnapshot.Streams.Delete(I);
end;

function TM3UReader.Read(const ASource: TSourceConfig): TSourceSnapshot;
var
  Content, User, Pass: string;
begin
  if ASource.Url.StartsWith(cSchemeHttp, cIgnoreCase) then
    // charset-detecting fetch (BOM/UTF-8/CP1251), long timeout for a bulk download
    Content := HttpGetText(ASource.Url.Trim, ASource.UserAgent, TimeoutBulkMs, ASource.Referer)
  else
    Content := DecodeBytes(TFile.ReadAllBytes(ASource.Url));

  // credentials for the credential-insensitive stream id: prefer the source's own
  // fields, else recover them from the playlist URL (get.php?username=…&password=…)
  User := ASource.Username;
  Pass := ASource.Password;
  if User = '' then
    User := UrlQueryParam(ASource.Url, cQueryUsername);
  if Pass = '' then
    Pass := UrlQueryParam(ASource.Url, cQueryPassword);

  Result := TSourceSnapshot.Create(ASource.Id);
  try
    ParseContent(Content, Result, User, Pass);
  except
    Result.Free;
    raise;
  end;
end;

end.
