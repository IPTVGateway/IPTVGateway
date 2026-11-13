unit IPTV.Api.Serializers;

{ Model <-> JSON. Keys are camelCase to match frontend/src/types.ts. Object
  builders return a fresh TJSONObject/TJSONArray the caller owns. Parsers apply
  incoming JSON onto a (possibly existing) model instance for upsert. }

interface

uses
  System.JSON, System.Generics.Collections,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg,
  IPTV.Model.CustomList;

function SourceToJson(const S: TSourceConfig): TJSONObject;
procedure SourceFromJson(const J: TJSONObject; const S: TSourceConfig);
function SourcesToJson(const L: TObjectList<TSourceConfig>): TJSONArray;

function StreamToJson(const S: TStreamItem): TJSONObject;
function StreamsToJson(const L: TStreamItemList): TJSONArray;
function CategoryToJson(const C: TCategory): TJSONObject;
function CategoriesToJson(const L: TCategoryList): TJSONArray;

function ProgrammeToJson(const P: TEpgProgramme): TJSONObject;
function ProgrammesToJson(const L: TEpgProgrammeList): TJSONArray;

function ListToJson(const L: TCustomList): TJSONObject;
procedure ListFromJson(const J: TJSONObject; const L: TCustomList);
function ListsToJson(const L: TObjectList<TCustomList>): TJSONArray;

function GroupToJson(const G: TCustomGroup): TJSONObject;
procedure GroupFromJson(const J: TJSONObject; const G: TCustomGroup);
function GroupsToJson(const L: TCustomGroupList): TJSONArray;

function ItemToJson(const I: TCustomItem): TJSONObject;
procedure ItemFromJson(const J: TJSONObject; const I: TCustomItem);
function ItemsToJson(const L: TCustomItemList): TJSONArray;

function IntArrayFromJson(const J: TJSONObject; const AName: string): TArray<Integer>;
function StrArrayToJson(const A: TArray<string>): TJSONArray;
function StrArrayFromJson(const A: TJSONArray): TArray<string>;

implementation

uses
  System.SysUtils,
  IPTV.Core.Utils;

{ helpers }

function ContentTypesToJson(const ACt: TContentTypes): TJSONArray;
var
  CT: TContentType;
begin
  Result := TJSONArray.Create;
  for CT := Low(TContentType) to High(TContentType) do
    if CT in ACt then
      Result.Add(ContentTypeNames[CT]);
end;

function ContentTypesFromJson(const A: TJSONArray): TContentTypes;
var
  V: TJSONValue;
begin
  Result := [];
  if A = nil then
    Exit(AllContentTypes);
  for V in A do
    Include(Result, ContentTypeFromString(V.Value));
end;

function StrArrayToJson(const A: TArray<string>): TJSONArray;
var
  S: string;
begin
  Result := TJSONArray.Create;
  for S in A do
    Result.Add(S);
end;

function StrArrayFromJson(const A: TJSONArray): TArray<string>;
var
  V: TJSONValue;
  L: TList<string>;
begin
  L := TList<string>.Create;
  try
    if A <> nil then
      for V in A do
        if V.Value.Trim <> '' then
          L.Add(V.Value.Trim);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

{ Source }

function SourceToJson(const S: TSourceConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(S.Id));
  Result.AddPair('name', S.Name);
  Result.AddPair('kind', SourceKindNames[S.Kind]);
  Result.AddPair('url', S.Url);
  Result.AddPair('username', S.Username);
  Result.AddPair('password', S.Password);
  Result.AddPair('epgUrl', S.EpgUrl);
  Result.AddPair('userAgent', S.UserAgent);
  Result.AddPair('referer', S.Referer);
  Result.AddPair('forceHls', TJSONBool.Create(S.ForceHls));
  Result.AddPair('preferOwnEpg', TJSONBool.Create(S.PreferOwnEpg));
  Result.AddPair('enabled', TJSONBool.Create(S.Enabled));
  Result.AddPair('contentTypes', ContentTypesToJson(S.ContentTypes));
  Result.AddPair('includeFilters', StrArrayToJson(S.IncludeFilters));
  Result.AddPair('excludeFilters', StrArrayToJson(S.ExcludeFilters));
  Result.AddPair('stripPrefixes', StrArrayToJson(S.StripPrefixes));
  Result.AddPair('stripSuffixes', StrArrayToJson(S.StripSuffixes));
  Result.AddPair('lastRefreshUtc', DateTimeToIsoUtc(S.LastRefreshUtc));
  // provider account info (read-only; filled on refresh — SourceFromJson ignores it)
  Result.AddPair('accountStatus', S.AccountStatus);
  Result.AddPair('expiresUtc', DateTimeToIsoUtc(S.ExpiresUtc));
  Result.AddPair('maxConnections', TJSONNumber.Create(S.MaxConnections));
end;

procedure SourceFromJson(const J: TJSONObject; const S: TSourceConfig);
begin
  S.Id := J.GetValue<Integer>('id', S.Id);
  S.Name := J.GetValue<string>('name', S.Name);
  S.Kind := SourceKindFromString(J.GetValue<string>('kind', SourceKindNames[S.Kind]));
  S.Url := J.GetValue<string>('url', S.Url);
  S.Username := J.GetValue<string>('username', S.Username);
  S.Password := J.GetValue<string>('password', S.Password);
  S.EpgUrl := J.GetValue<string>('epgUrl', S.EpgUrl);
  S.UserAgent := J.GetValue<string>('userAgent', S.UserAgent);
  S.Referer := J.GetValue<string>('referer', S.Referer);
  S.ForceHls := J.GetValue<Boolean>('forceHls', S.ForceHls);
  S.PreferOwnEpg := J.GetValue<Boolean>('preferOwnEpg', S.PreferOwnEpg);
  S.Enabled := J.GetValue<Boolean>('enabled', S.Enabled);
  if J.GetValue('contentTypes') is TJSONArray then
    S.ContentTypes := ContentTypesFromJson(J.GetValue('contentTypes') as TJSONArray);
  if J.GetValue('includeFilters') is TJSONArray then
    S.IncludeFilters := StrArrayFromJson(J.GetValue('includeFilters') as TJSONArray);
  if J.GetValue('excludeFilters') is TJSONArray then
    S.ExcludeFilters := StrArrayFromJson(J.GetValue('excludeFilters') as TJSONArray);
  if J.GetValue('stripPrefixes') is TJSONArray then
    S.StripPrefixes := StrArrayFromJson(J.GetValue('stripPrefixes') as TJSONArray);
  if J.GetValue('stripSuffixes') is TJSONArray then
    S.StripSuffixes := StrArrayFromJson(J.GetValue('stripSuffixes') as TJSONArray);
end;

function SourcesToJson(const L: TObjectList<TSourceConfig>): TJSONArray;
var
  S: TSourceConfig;
begin
  Result := TJSONArray.Create;
  for S in L do
    Result.Add(SourceToJson(S));
end;

{ Stream / Category }

function StreamToJson(const S: TStreamItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(S.Id));
  Result.AddPair('sourceId', TJSONNumber.Create(S.SourceId));
  Result.AddPair('contentType', ContentTypeNames[S.ContentType]);
  Result.AddPair('name', S.Name);
  Result.AddPair('logo', S.Logo);
  Result.AddPair('groupTitle', S.GroupTitle);
  Result.AddPair('tvgId', S.TvgId);
  Result.AddPair('archiveDays', TJSONNumber.Create(S.ArchiveDays));
  Result.AddPair('isNew', TJSONBool.Create(S.IsNew));
  Result.AddPair('seenAtUtc', DateTimeToIsoUtc(S.SeenAtUtc));
end;

function StreamsToJson(const L: TStreamItemList): TJSONArray;
var
  S: TStreamItem;
begin
  Result := TJSONArray.Create;
  for S in L do
    Result.Add(StreamToJson(S));
end;

function CategoryToJson(const C: TCategory): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(C.Id));
  Result.AddPair('sourceId', TJSONNumber.Create(C.SourceId));
  Result.AddPair('upstreamId', C.UpstreamId);
  Result.AddPair('contentType', ContentTypeNames[C.ContentType]);
  Result.AddPair('name', C.Name);
  Result.AddPair('isNew', TJSONBool.Create(C.IsNew));
  Result.AddPair('seenAtUtc', DateTimeToIsoUtc(C.SeenAtUtc));
end;

function CategoriesToJson(const L: TCategoryList): TJSONArray;
var
  C: TCategory;
begin
  Result := TJSONArray.Create;
  for C in L do
    Result.Add(CategoryToJson(C));
end;

{ EPG }

function ProgrammeToJson(const P: TEpgProgramme): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('channelTvgId', P.ChannelTvgId);
  Result.AddPair('startUtc', DateTimeToIsoUtc(P.StartUtc));
  Result.AddPair('stopUtc', DateTimeToIsoUtc(P.StopUtc));
  Result.AddPair('title', P.Title);
  Result.AddPair('description', P.Description);
  Result.AddPair('category', P.Category);
end;

function ProgrammesToJson(const L: TEpgProgrammeList): TJSONArray;
var
  P: TEpgProgramme;
begin
  Result := TJSONArray.Create;
  for P in L do
    Result.Add(ProgrammeToJson(P));
end;

{ List / Group / Item }

function ListToJson(const L: TCustomList): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(L.Id));
  Result.AddPair('name', L.Name);
  Result.AddPair('outputUsername', L.OutputUsername);
  Result.AddPair('outputPassword', L.OutputPassword);
  Result.AddPair('enabled', TJSONBool.Create(L.Enabled));
end;

procedure ListFromJson(const J: TJSONObject; const L: TCustomList);
begin
  L.Id := J.GetValue<Integer>('id', L.Id);
  L.Name := J.GetValue<string>('name', L.Name);
  L.OutputUsername := J.GetValue<string>('outputUsername', L.OutputUsername);
  L.OutputPassword := J.GetValue<string>('outputPassword', L.OutputPassword);
  L.Enabled := J.GetValue<Boolean>('enabled', L.Enabled);
end;

function ListsToJson(const L: TObjectList<TCustomList>): TJSONArray;
var
  X: TCustomList;
begin
  Result := TJSONArray.Create;
  for X in L do
    Result.Add(ListToJson(X));
end;

function GroupToJson(const G: TCustomGroup): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(G.Id));
  Result.AddPair('listId', TJSONNumber.Create(G.ListId));
  Result.AddPair('name', G.Name);
  Result.AddPair('contentType', ContentTypeNames[G.ContentType]);
  Result.AddPair('isFavorite', TJSONBool.Create(G.IsFavorite));
  Result.AddPair('sortOrder', TJSONNumber.Create(G.SortOrder));
end;

procedure GroupFromJson(const J: TJSONObject; const G: TCustomGroup);
begin
  G.Id := J.GetValue<Integer>('id', G.Id);
  G.ListId := J.GetValue<Integer>('listId', G.ListId);
  G.Name := J.GetValue<string>('name', G.Name);
  G.ContentType := ContentTypeFromString(J.GetValue<string>('contentType', ContentTypeNames[G.ContentType]));
  G.IsFavorite := J.GetValue<Boolean>('isFavorite', G.IsFavorite);
end;

function GroupsToJson(const L: TCustomGroupList): TJSONArray;
var
  G: TCustomGroup;
begin
  Result := TJSONArray.Create;
  for G in L do
    Result.Add(GroupToJson(G));
end;

function ItemToJson(const I: TCustomItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(I.Id));
  Result.AddPair('listId', TJSONNumber.Create(I.ListId));
  Result.AddPair('streamItemId', TJSONNumber.Create(I.StreamItemId));
  Result.AddPair('customGroupId', TJSONNumber.Create(I.CustomGroupId));
  Result.AddPair('contentType', ContentTypeNames[I.ContentType]);
  Result.AddPair('displayName', I.DisplayName);
  Result.AddPair('logoOverride', I.LogoOverride);
  Result.AddPair('tvgIdOverride', I.TvgIdOverride);
  Result.AddPair('channelNumber', TJSONNumber.Create(I.ChannelNumber));
  // read-only upstream values (so the UI can label items without an override)
  Result.AddPair('streamName', I.StreamName);
  Result.AddPair('streamLogo', I.StreamLogo);
  Result.AddPair('streamTvgId', I.StreamTvgId);
  Result.AddPair('streamSourceId', TJSONNumber.Create(I.StreamSourceId));
  Result.AddPair('streamArchiveDays', TJSONNumber.Create(I.StreamArchiveDays));
end;

procedure ItemFromJson(const J: TJSONObject; const I: TCustomItem);
begin
  I.Id := J.GetValue<Integer>('id', I.Id);
  I.ListId := J.GetValue<Integer>('listId', I.ListId);
  I.StreamItemId := J.GetValue<Integer>('streamItemId', I.StreamItemId);
  I.CustomGroupId := J.GetValue<Integer>('customGroupId', I.CustomGroupId);
  I.DisplayName := J.GetValue<string>('displayName', I.DisplayName);
  I.LogoOverride := J.GetValue<string>('logoOverride', I.LogoOverride);
  I.TvgIdOverride := J.GetValue<string>('tvgIdOverride', I.TvgIdOverride);
  I.ContentType := ContentTypeFromString(J.GetValue<string>('contentType', ContentTypeNames[I.ContentType]));
  I.ChannelNumber := J.GetValue<Integer>('channelNumber', I.ChannelNumber);
end;

function ItemsToJson(const L: TCustomItemList): TJSONArray;
var
  I: TCustomItem;
begin
  Result := TJSONArray.Create;
  for I in L do
    Result.Add(ItemToJson(I));
end;

function IntArrayFromJson(const J: TJSONObject; const AName: string): TArray<Integer>;
var
  Arr: TJSONArray;
  V: TJSONValue;
  L: TList<Integer>;
begin
  L := TList<Integer>.Create;
  try
    if J.GetValue(AName) is TJSONArray then
    begin
      Arr := J.GetValue(AName) as TJSONArray;
      for V in Arr do
        if V is TJSONNumber then
          L.Add((V as TJSONNumber).AsInt);
    end;
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

end.
