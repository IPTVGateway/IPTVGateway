unit IPTV.Api.Serializers;

{ Model <-> JSON. Keys are camelCase to match frontend/src/types.ts. Object
  builders return a fresh TJSONObject/TJSONArray the caller owns. Parsers apply
  incoming JSON onto a (possibly existing) model instance for upsert. }

interface

uses
  // RTL
  System.JSON,
  System.Generics.Collections,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList;

const
  // HTTP status codes (shared by the API resources and the Plex client)
  cHttpOk = 200;
  cHttpBadRequest = 400;
  cHttpUnauthorized = 401;
  cHttpForbidden = 403;
  cHttpNotFound = 404;
  cHttpLengthRequired = 411;
  cHttpPayloadTooLarge = 413;
  cHttpInternalServerError = 500;
  cHttpServiceUnavailable = 503;

  // host named in our own URLs when publicBaseUrl is unset/unparseable
  cDefaultPublicHost = 'localhost';

  // what the media servers (Plex/Jellyfin tuner surfaces) publish: linear channels only
  cLinearContentTypes = [ctLive, ctRadio];

/// <summary>Source config as JSON, password included (settings export = a backup).</summary>
function SourceToJson(const ASource: TSourceConfig): TJSONObject;
/// <summary>Source config as the admin API returns it: the provider password is
/// write-only ("password" is always '', "hasPassword" tells whether one is stored) and
/// secret query values in "url" / "epgUrl" are masked ('***', see MaskUrlQuerySecrets).</summary>
function SourceToAdminJson(const ASource: TSourceConfig): TJSONObject;
/// <summary>Source configs as the admin API returns them (see SourceToAdminJson).</summary>
function SourcesToAdminJson(const AList: TObjectList<TSourceConfig>): TJSONArray;
/// <summary>Applies JSON fields onto an existing source config. A missing or empty
/// "password" keeps the stored password, a non-empty one replaces it and
/// "clearPassword": true clears it.</summary>
procedure SourceFromJson(const AJson: TJSONObject; const ASource: TSourceConfig);
/// <summary>Source configs as a JSON array.</summary>
function SourcesToJson(const AList: TObjectList<TSourceConfig>): TJSONArray;

/// <summary>Catalog stream as JSON.</summary>
function StreamToJson(const AStream: TStreamItem): TJSONObject;
/// <summary>Catalog streams as a JSON array.</summary>
function StreamsToJson(const AList: TStreamItemList): TJSONArray;
/// <summary>Catalog category as JSON.</summary>
function CategoryToJson(const ACategory: TCategory): TJSONObject;
/// <summary>Catalog categories as a JSON array.</summary>
function CategoriesToJson(const AList: TCategoryList): TJSONArray;

/// <summary>EPG programme as JSON.</summary>
function ProgrammeToJson(const AProgramme: TEpgProgramme): TJSONObject;
/// <summary>EPG programmes as a JSON array.</summary>
function ProgrammesToJson(const AList: TEpgProgrammeList): TJSONArray;

/// <summary>Custom list as JSON.</summary>
function ListToJson(const AList: TCustomList): TJSONObject;
/// <summary>Applies JSON fields onto an existing custom list.</summary>
procedure ListFromJson(const AJson: TJSONObject; const AList: TCustomList);
/// <summary>Custom lists as a JSON array.</summary>
function ListsToJson(const AList: TObjectList<TCustomList>): TJSONArray;

/// <summary>A mirror bouquet's provider credentials as the admin API returns them:
/// [ { sourceId, url, username, password: '', hasPassword } ] (password write-only).</summary>
function MirrorCredentialsToJson(const ACredentials: TArray<TMirrorCredential>): TJSONArray;
/// <summary>Mirror credentials from such a JSON array (non-objects skipped; missing
/// fields '' / 0). A row with a missing or empty "password" keeps that source's
/// password from AStored, a non-empty one sets it and "clearPassword": true clears it.</summary>
function MirrorCredentialsFromJson(const AArray: TJSONArray;
  const AStored: TArray<TMirrorCredential> = nil): TArray<TMirrorCredential>;

/// <summary>Custom group as JSON.</summary>
function GroupToJson(const AGroup: TCustomGroup): TJSONObject;
/// <summary>Applies JSON fields onto an existing custom group.</summary>
procedure GroupFromJson(const AJson: TJSONObject; const AGroup: TCustomGroup);
/// <summary>Custom groups as a JSON array.</summary>
function GroupsToJson(const AList: TCustomGroupList): TJSONArray;

/// <summary>List item as JSON (incl. read-only upstream values).</summary>
function ItemToJson(const AItem: TCustomItem): TJSONObject;
/// <summary>Applies JSON fields onto an existing list item.</summary>
procedure ItemFromJson(const AJson: TJSONObject; const AItem: TCustomItem);
/// <summary>List items as a JSON array.</summary>
function ItemsToJson(const AList: TCustomItemList): TJSONArray;

/// <summary>Integer array under AName (non-numbers skipped; empty when absent).</summary>
function IntArrayFromJson(const AJson: TJSONObject; const AName: string): TArray<Integer>;
/// <summary>String array as a JSON array.</summary>
function StrArrayToJson(const AValues: TArray<string>): TJSONArray;
/// <summary>Trimmed, non-empty strings of a JSON array (nil gives an empty array).</summary>
function StrArrayFromJson(const AArray: TJSONArray): TArray<string>;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Core.Utils;

const
  // write-only secrets: the key and its "is one stored?" companion
  cFieldPassword = 'password';
  cFieldHasPassword = 'hasPassword';
  cFieldClearPassword = 'clearPassword';
  cFieldUrl = 'url';
  cFieldEpgUrl = 'epgUrl';

{ helpers }

function ContentTypesToJson(const ACt: TContentTypes): TJSONArray;
var
  lCT: TContentType;
begin
  Result := TJSONArray.Create;
  for lCT := Low(TContentType) to High(TContentType) do
    if lCT in ACt then
      Result.Add(ContentTypeNames[lCT]);
end;

function ContentTypesFromJson(const AArray: TJSONArray): TContentTypes;
var
  lValue: TJSONValue;
begin
  Result := [];
  if AArray = nil then
    Exit(AllContentTypes);
  for lValue in AArray do
    Include(Result, ContentTypeFromString(lValue.Value));
end;

function StrArrayToJson(const AValues: TArray<string>): TJSONArray;
var
  lStr: string;
begin
  Result := TJSONArray.Create;
  for lStr in AValues do
    Result.Add(lStr);
end;

function StrArrayFromJson(const AArray: TJSONArray): TArray<string>;
var
  lValue: TJSONValue;
  lList: TList<string>;
begin
  lList := TList<string>.Create;
  try
    if AArray <> nil then
      for lValue in AArray do
        if lValue.Value.Trim <> '' then
          lList.Add(lValue.Value.Trim);
    Result := lList.ToArray;
  finally
    FreeAndNil(lList);
  end;
end;

{ Source }

function SourceToJson(const ASource: TSourceConfig): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(ASource.Id));
  Result.AddPair('name', ASource.Name);
  Result.AddPair('kind', SourceKindNames[ASource.Kind]);
  Result.AddPair('url', ASource.Url);
  Result.AddPair('username', ASource.Username);
  Result.AddPair('password', ASource.Password);
  Result.AddPair('epgUrl', ASource.EpgUrl);
  Result.AddPair('userAgent', ASource.UserAgent);
  Result.AddPair('referer', ASource.Referer);
  Result.AddPair('forceHls', TJSONBool.Create(ASource.ForceHls));
  Result.AddPair('preferOwnEpg', TJSONBool.Create(ASource.PreferOwnEpg));
  Result.AddPair('enabled', TJSONBool.Create(ASource.Enabled));
  Result.AddPair('contentTypes', ContentTypesToJson(ASource.ContentTypes));
  Result.AddPair('includeFilters', StrArrayToJson(ASource.IncludeFilters));
  Result.AddPair('excludeFilters', StrArrayToJson(ASource.ExcludeFilters));
  Result.AddPair('stripPrefixes', StrArrayToJson(ASource.StripPrefixes));
  Result.AddPair('stripSuffixes', StrArrayToJson(ASource.StripSuffixes));
  Result.AddPair('lastRefreshUtc', DateTimeToIsoUtc(ASource.LastRefreshUtc));
  // provider account info (read-only; filled on refresh — SourceFromJson ignores it)
  Result.AddPair('accountStatus', ASource.AccountStatus);
  Result.AddPair('expiresUtc', DateTimeToIsoUtc(ASource.ExpiresUtc));
  Result.AddPair('maxConnections', TJSONNumber.Create(ASource.MaxConnections));
end;

function SourceToAdminJson(const ASource: TSourceConfig): TJSONObject;
begin
  Result := SourceToJson(ASource);
  // write-only: the browser never gets the provider password back
  Result.RemovePair(cFieldPassword).Free;
  Result.AddPair(cFieldPassword, '');
  Result.AddPair(cFieldHasPassword, TJSONBool.Create(ASource.Password <> ''));
  // an M3U URL often carries the account in its query: hide those values too
  Result.RemovePair(cFieldUrl).Free;
  Result.AddPair(cFieldUrl, MaskUrlQuerySecrets(ASource.Url));
  Result.RemovePair(cFieldEpgUrl).Free;
  Result.AddPair(cFieldEpgUrl, MaskUrlQuerySecrets(ASource.EpgUrl));
end;

// a write-only password from an admin body: "clearPassword": true clears it, a
// non-empty "password" sets it, a missing or empty one keeps AStored
function WriteOnlyPassword(const AJson: TJSONObject; const AStored: string): string;
var
  lGiven: string;
begin
  if AJson.GetValue<Boolean>(cFieldClearPassword, False) then
    Exit('');
  lGiven := AJson.GetValue<string>(cFieldPassword, '');
  if lGiven <> '' then
    Result := lGiven
  else
    Result := AStored;
end;

function SourcesToAdminJson(const AList: TObjectList<TSourceConfig>): TJSONArray;
var
  lSource: TSourceConfig;
begin
  Result := TJSONArray.Create;
  for lSource in AList do
    Result.Add(SourceToAdminJson(lSource));
end;

procedure SourceFromJson(const AJson: TJSONObject; const ASource: TSourceConfig);
begin
  ASource.Id := AJson.GetValue<Integer>('id', ASource.Id);
  ASource.Name := AJson.GetValue<string>('name', ASource.Name);
  ASource.Kind := SourceKindFromString(AJson.GetValue<string>('kind', SourceKindNames[ASource.Kind]));
  ASource.Url := AJson.GetValue<string>('url', ASource.Url);
  ASource.Username := AJson.GetValue<string>('username', ASource.Username);
  // write-only in the admin API: missing/'' = keep the stored password
  ASource.Password := WriteOnlyPassword(AJson, ASource.Password);
  ASource.EpgUrl := AJson.GetValue<string>('epgUrl', ASource.EpgUrl);
  ASource.UserAgent := AJson.GetValue<string>('userAgent', ASource.UserAgent);
  ASource.Referer := AJson.GetValue<string>('referer', ASource.Referer);
  ASource.ForceHls := AJson.GetValue<Boolean>('forceHls', ASource.ForceHls);
  ASource.PreferOwnEpg := AJson.GetValue<Boolean>('preferOwnEpg', ASource.PreferOwnEpg);
  ASource.Enabled := AJson.GetValue<Boolean>('enabled', ASource.Enabled);
  if AJson.GetValue('contentTypes') is TJSONArray then
    ASource.ContentTypes := ContentTypesFromJson(AJson.GetValue('contentTypes') as TJSONArray);
  if AJson.GetValue('includeFilters') is TJSONArray then
    ASource.IncludeFilters := StrArrayFromJson(AJson.GetValue('includeFilters') as TJSONArray);
  if AJson.GetValue('excludeFilters') is TJSONArray then
    ASource.ExcludeFilters := StrArrayFromJson(AJson.GetValue('excludeFilters') as TJSONArray);
  if AJson.GetValue('stripPrefixes') is TJSONArray then
    ASource.StripPrefixes := StrArrayFromJson(AJson.GetValue('stripPrefixes') as TJSONArray);
  if AJson.GetValue('stripSuffixes') is TJSONArray then
    ASource.StripSuffixes := StrArrayFromJson(AJson.GetValue('stripSuffixes') as TJSONArray);
end;

function SourcesToJson(const AList: TObjectList<TSourceConfig>): TJSONArray;
var
  lSource: TSourceConfig;
begin
  Result := TJSONArray.Create;
  for lSource in AList do
    Result.Add(SourceToJson(lSource));
end;

{ Stream / Category }

function StreamToJson(const AStream: TStreamItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AStream.Id));
  Result.AddPair('sourceId', TJSONNumber.Create(AStream.SourceId));
  Result.AddPair('contentType', ContentTypeNames[AStream.ContentType]);
  Result.AddPair('name', AStream.Name);
  Result.AddPair('logo', AStream.Logo);
  Result.AddPair('groupTitle', AStream.GroupTitle);
  Result.AddPair('tvgId', AStream.TvgId);
  Result.AddPair('archiveDays', TJSONNumber.Create(AStream.ArchiveDays));
  Result.AddPair('isNew', TJSONBool.Create(AStream.IsNew));
  Result.AddPair('seenAtUtc', DateTimeToIsoUtc(AStream.SeenAtUtc));
end;

function StreamsToJson(const AList: TStreamItemList): TJSONArray;
var
  lStream: TStreamItem;
begin
  Result := TJSONArray.Create;
  for lStream in AList do
    Result.Add(StreamToJson(lStream));
end;

function CategoryToJson(const ACategory: TCategory): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(ACategory.Id));
  Result.AddPair('sourceId', TJSONNumber.Create(ACategory.SourceId));
  Result.AddPair('upstreamId', ACategory.UpstreamId);
  Result.AddPair('contentType', ContentTypeNames[ACategory.ContentType]);
  Result.AddPair('name', ACategory.Name);
  Result.AddPair('isNew', TJSONBool.Create(ACategory.IsNew));
  Result.AddPair('seenAtUtc', DateTimeToIsoUtc(ACategory.SeenAtUtc));
  Result.AddPair('newCount', TJSONNumber.Create(ACategory.NewCount));
end;

function CategoriesToJson(const AList: TCategoryList): TJSONArray;
var
  lCategory: TCategory;
begin
  Result := TJSONArray.Create;
  for lCategory in AList do
    Result.Add(CategoryToJson(lCategory));
end;

{ EPG }

function ProgrammeToJson(const AProgramme: TEpgProgramme): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('channelTvgId', AProgramme.ChannelTvgId);
  Result.AddPair('startUtc', DateTimeToIsoUtc(AProgramme.StartUtc));
  Result.AddPair('stopUtc', DateTimeToIsoUtc(AProgramme.StopUtc));
  Result.AddPair('title', AProgramme.Title);
  Result.AddPair('description', AProgramme.Description);
  Result.AddPair('category', AProgramme.Category);
end;

function ProgrammesToJson(const AList: TEpgProgrammeList): TJSONArray;
var
  lProgramme: TEpgProgramme;
begin
  Result := TJSONArray.Create;
  for lProgramme in AList do
    Result.Add(ProgrammeToJson(lProgramme));
end;

{ List / Group / Item }

function ListToJson(const AList: TCustomList): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AList.Id));
  Result.AddPair('name', AList.Name);
  Result.AddPair('outputUsername', AList.OutputUsername);
  Result.AddPair('outputPassword', AList.OutputPassword);
  Result.AddPair('enabled', TJSONBool.Create(AList.Enabled));
  Result.AddPair('mirrorOfListId', TJSONNumber.Create(AList.MirrorOfListId));
end;

procedure ListFromJson(const AJson: TJSONObject; const AList: TCustomList);
begin
  AList.Id := AJson.GetValue<Integer>('id', AList.Id);
  AList.Name := AJson.GetValue<string>('name', AList.Name);
  AList.OutputUsername := AJson.GetValue<string>('outputUsername', AList.OutputUsername);
  AList.OutputPassword := AJson.GetValue<string>('outputPassword', AList.OutputPassword);
  AList.Enabled := AJson.GetValue<Boolean>('enabled', AList.Enabled);
  AList.MirrorOfListId := AJson.GetValue<Integer>('mirrorOfListId', AList.MirrorOfListId);
end;

function ListsToJson(const AList: TObjectList<TCustomList>): TJSONArray;
var
  lList: TCustomList;
begin
  Result := TJSONArray.Create;
  for lList in AList do
    Result.Add(ListToJson(lList));
end;

function MirrorCredentialsToJson(const ACredentials: TArray<TMirrorCredential>): TJSONArray;
var
  lCredential: TMirrorCredential;
  lEntry: TJSONObject;
begin
  Result := TJSONArray.Create;
  for lCredential in ACredentials do
  begin
    lEntry := TJSONObject.Create;
    lEntry.AddPair('sourceId', TJSONNumber.Create(lCredential.SourceId));
    lEntry.AddPair('url', lCredential.Url);
    lEntry.AddPair('username', lCredential.Username);
    lEntry.AddPair(cFieldPassword, ''); // write-only
    lEntry.AddPair(cFieldHasPassword, TJSONBool.Create(lCredential.Password <> ''));
    Result.AddElement(lEntry);
  end;
end;

function MirrorCredentialsFromJson(const AArray: TJSONArray;
  const AStored: TArray<TMirrorCredential>): TArray<TMirrorCredential>;
var
  lValue: TJSONValue;
  lCredential: TMirrorCredential;
  lStored: TMirrorCredential;
  lStoredPassword: string;
begin
  Result := nil;
  if AArray = nil then
    Exit;
  for lValue in AArray do
    if lValue is TJSONObject then
    begin
      lCredential.SourceId := TJSONObject(lValue).GetValue<Integer>('sourceId', 0);
      lCredential.Url := TJSONObject(lValue).GetValue<string>('url', '');
      lCredential.Username := TJSONObject(lValue).GetValue<string>('username', '');
      // missing/'': keep what is stored for that source (the GET never returns it)
      lStoredPassword := '';
      for lStored in AStored do
        if lStored.SourceId = lCredential.SourceId then
          lStoredPassword := lStored.Password;
      lCredential.Password := WriteOnlyPassword(TJSONObject(lValue), lStoredPassword);
      Result := Result + [lCredential];
    end;
end;

function GroupToJson(const AGroup: TCustomGroup): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AGroup.Id));
  Result.AddPair('listId', TJSONNumber.Create(AGroup.ListId));
  Result.AddPair('name', AGroup.Name);
  Result.AddPair('contentType', ContentTypeNames[AGroup.ContentType]);
  Result.AddPair('isFavorite', TJSONBool.Create(AGroup.IsFavorite));
  Result.AddPair('sortOrder', TJSONNumber.Create(AGroup.SortOrder));
end;

procedure GroupFromJson(const AJson: TJSONObject; const AGroup: TCustomGroup);
begin
  AGroup.Id := AJson.GetValue<Integer>('id', AGroup.Id);
  AGroup.ListId := AJson.GetValue<Integer>('listId', AGroup.ListId);
  AGroup.Name := AJson.GetValue<string>('name', AGroup.Name);
  AGroup.ContentType := ContentTypeFromString(
    AJson.GetValue<string>('contentType', ContentTypeNames[AGroup.ContentType]));
  AGroup.IsFavorite := AJson.GetValue<Boolean>('isFavorite', AGroup.IsFavorite);
end;

function GroupsToJson(const AList: TCustomGroupList): TJSONArray;
var
  lGroup: TCustomGroup;
begin
  Result := TJSONArray.Create;
  for lGroup in AList do
    Result.Add(GroupToJson(lGroup));
end;

function ItemToJson(const AItem: TCustomItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('id', TJSONNumber.Create(AItem.Id));
  Result.AddPair('listId', TJSONNumber.Create(AItem.ListId));
  Result.AddPair('streamItemId', TJSONNumber.Create(AItem.StreamItemId));
  Result.AddPair('customGroupId', TJSONNumber.Create(AItem.CustomGroupId));
  Result.AddPair('contentType', ContentTypeNames[AItem.ContentType]);
  Result.AddPair('displayName', AItem.DisplayName);
  Result.AddPair('logoOverride', AItem.LogoOverride);
  Result.AddPair('tvgIdOverride', AItem.TvgIdOverride);
  Result.AddPair('channelNumber', TJSONNumber.Create(AItem.ChannelNumber));
  // read-only upstream values (so the UI can label items without an override)
  Result.AddPair('streamName', AItem.StreamName);
  Result.AddPair('streamLogo', AItem.StreamLogo);
  Result.AddPair('streamTvgId', AItem.StreamTvgId);
  Result.AddPair('streamSourceId', TJSONNumber.Create(AItem.StreamSourceId));
  Result.AddPair('streamArchiveDays', TJSONNumber.Create(AItem.StreamArchiveDays));
end;

procedure ItemFromJson(const AJson: TJSONObject; const AItem: TCustomItem);
begin
  AItem.Id := AJson.GetValue<Integer>('id', AItem.Id);
  AItem.ListId := AJson.GetValue<Integer>('listId', AItem.ListId);
  AItem.StreamItemId := AJson.GetValue<Integer>('streamItemId', AItem.StreamItemId);
  AItem.CustomGroupId := AJson.GetValue<Integer>('customGroupId', AItem.CustomGroupId);
  AItem.DisplayName := AJson.GetValue<string>('displayName', AItem.DisplayName);
  AItem.LogoOverride := AJson.GetValue<string>('logoOverride', AItem.LogoOverride);
  AItem.TvgIdOverride := AJson.GetValue<string>('tvgIdOverride', AItem.TvgIdOverride);
  AItem.ContentType := ContentTypeFromString(
    AJson.GetValue<string>('contentType', ContentTypeNames[AItem.ContentType]));
  AItem.ChannelNumber := AJson.GetValue<Integer>('channelNumber', AItem.ChannelNumber);
end;

function ItemsToJson(const AList: TCustomItemList): TJSONArray;
var
  lItem: TCustomItem;
begin
  Result := TJSONArray.Create;
  for lItem in AList do
    Result.Add(ItemToJson(lItem));
end;

function IntArrayFromJson(const AJson: TJSONObject; const AName: string): TArray<Integer>;
var
  lArr: TJSONArray;
  lValue: TJSONValue;
  lList: TList<Integer>;
begin
  lList := TList<Integer>.Create;
  try
    if AJson.GetValue(AName) is TJSONArray then
    begin
      lArr := AJson.GetValue(AName) as TJSONArray;
      for lValue in lArr do
        if lValue is TJSONNumber then
          lList.Add((lValue as TJSONNumber).AsInt);
    end;
    Result := lList.ToArray;
  finally
    FreeAndNil(lList);
  end;
end;

end.
