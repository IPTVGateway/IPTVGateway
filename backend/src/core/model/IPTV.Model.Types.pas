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

function SourceKindFromString(const AValue: string): TSourceKind;
function ContentTypeFromString(const AValue: string): TContentType;

implementation

uses
  System.SysUtils;

function SourceKindFromString(const AValue: string): TSourceKind;
begin
  if SameText(AValue, 'xtream') then
    Result := skXtream
  else if SameText(AValue, 'stalker') then
    Result := skStalker
  else
    Result := skM3U;
end;

function ContentTypeFromString(const AValue: string): TContentType;
var
  CT: TContentType;
begin
  for CT := Low(TContentType) to High(TContentType) do
    if SameText(AValue, ContentTypeNames[CT]) then
      Exit(CT);
  Result := ctLive;
end;

end.
