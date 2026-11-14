unit IPTV.Model.Types;

{ Shared enums and small value types used across the whole core.
  Keep this unit dependency-free so every other unit can use it. }

interface

type
  /// Upstream provider kind.
  TSourceKind = (skXtream, skM3U, skStalker);

  /// Content category a stream belongs to. Each source can enable/disable
  /// these independently (see TSourceConfig content toggles).
  TContentType = (ctLive, ctMovie, ctSeries, ctRadio);
  TContentTypes = set of TContentType;

const
  SourceKindNames: array[TSourceKind] of string = ('xtream', 'm3u', 'stalker');
  ContentTypeNames: array[TContentType] of string = ('live', 'movie', 'series', 'radio');

  AllContentTypes: TContentTypes = [ctLive, ctMovie, ctSeries, ctRadio];

  // Unicode vertical-bar glyphs providers decorate channel names with instead of
  // the ASCII pipe ("┃F1 TV┃", "│NL│"). Treated as name separators wherever a
  // name is stripped, filtered or matched - keep every user of them in lockstep.
  cSepBrokenBar = #$00A6;          // ¦ broken bar
  cSepBoxLight = #$2502;           // │ box-drawings light vertical
  cSepBoxHeavy = #$2503;           // ┃ box-drawings heavy vertical
  cSepTripleDashLight = #$2506;    // ┆ light triple-dash vertical
  cSepTripleDashHeavy = #$2507;    // ┇ heavy triple-dash vertical
  cSepQuadDashLight = #$250A;      // ┊ light quadruple-dash vertical
  cSepQuadDashHeavy = #$250B;      // ┋ heavy quadruple-dash vertical
  cSepFullwidthBar = #$FF5C;       // ｜ fullwidth vertical line

/// Parses a source kind name (case-insensitive); unknown names give skM3U.
function SourceKindFromString(const AValue: string): TSourceKind;
/// Parses a content type name (case-insensitive); unknown names give ctLive.
function ContentTypeFromString(const AValue: string): TContentType;
/// Strict parse of a content type name (case-insensitive): False for an unknown name.
function TryContentTypeFromString(const AValue: string; out AContentType: TContentType): Boolean;

implementation

uses
  // RTL
  System.SysUtils;

function SourceKindFromString(const AValue: string): TSourceKind;
begin
  if SameText(AValue, SourceKindNames[skXtream]) then
    Result := skXtream
  else if SameText(AValue, SourceKindNames[skStalker]) then
    Result := skStalker
  else
    Result := skM3U;
end;

function ContentTypeFromString(const AValue: string): TContentType;
var
  lContentType: TContentType;
begin
  for lContentType := Low(TContentType) to High(TContentType) do
    if SameText(AValue, ContentTypeNames[lContentType]) then
      Exit(lContentType);
  Result := ctLive;
end;

function TryContentTypeFromString(const AValue: string; out AContentType: TContentType): Boolean;
var
  lContentType: TContentType;
begin
  for lContentType := Low(TContentType) to High(TContentType) do
    if SameText(AValue, ContentTypeNames[lContentType]) then
    begin
      AContentType := lContentType;
      Exit(True);
    end;
  AContentType := ctLive;
  Result := False;
end;

end.
