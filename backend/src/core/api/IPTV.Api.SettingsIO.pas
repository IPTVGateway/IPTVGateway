unit IPTV.Api.SettingsIO;

(* Portable settings bundle (export / import) as plain store operations, with NO
   MARS/web dependency so it is unit-testable against a temp store.

   The bundle is { version, sources[], lists[ {..., groups[], items[]} ] }. Each
   item carries its upstream stream (sourceName + upstreamId + url + metadata) so
   importing onto a fresh instance recreates the catalog rows for the chosen
   channels and re-links the items by upstream URL - a 1:1 clone without needing a
   refresh first. A later refresh matches those rows by source+content+upstreamId.

   The app-level config (refresh time / proxy) is NOT handled here; the API
   resource adds/applies it around these calls (it needs the app context). *)

interface

uses
  // RTL
  System.JSON,
  // own units
  IPTV.Storage.Intf;

type
  /// How many sources, lists, groups and items an import created.
  TImportCounts = record
    Sources, Lists, Groups, Items: Integer;
  end;

/// Build the store-backed bundle (version + sources + lists[groups,items]).
function ExportStoreSettings(const AStore: IStore): TJSONObject;
/// Replace the store-backed config from a bundle. Wipes existing sources + lists
/// then recreates sources, the chosen channels' catalog rows, lists, groups and
/// items. Returns how many of each were created.
function ImportStoreSettings(const AStore: IStore; const ABody: TJSONObject): TImportCounts;

implementation

uses
  // RTL
  System.SysUtils,
  System.Generics.Collections,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.CustomList,
  IPTV.Api.Serializers;

const
  cBundleVersion = 1;   // the 'version' an export writes
  cStreamKeySep = '|';  // joins sourceName|contentType|upstreamId|upstreamUrl into a dedupe key

function StreamExportJson(const ASourceName: string; const AStream: TStreamItem): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('sourceName', ASourceName);
  Result.AddPair('contentType', ContentTypeNames[AStream.ContentType]);
  Result.AddPair('upstreamId', AStream.UpstreamId);
  Result.AddPair('name', AStream.Name);
  Result.AddPair('logo', AStream.Logo);
  Result.AddPair('groupTitle', AStream.GroupTitle);
  Result.AddPair('categoryUpstreamId', AStream.CategoryUpstreamId);
  Result.AddPair('tvgId', AStream.TvgId);
  Result.AddPair('tvgName', AStream.TvgName);
  Result.AddPair('upstreamUrl', AStream.UpstreamUrl);
end;

function StreamFromExportJson(const AJson: TJSONObject; ASourceId: Integer): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.SourceId := ASourceId;
  Result.ContentType := ContentTypeFromString(AJson.GetValue<string>('contentType', ContentTypeNames[ctLive]));
  Result.UpstreamId := AJson.GetValue<string>('upstreamId', '');
  Result.Name := AJson.GetValue<string>('name', '');
  Result.Logo := AJson.GetValue<string>('logo', '');
  Result.GroupTitle := AJson.GetValue<string>('groupTitle', '');
  Result.CategoryUpstreamId := AJson.GetValue<string>('categoryUpstreamId', '');
  Result.TvgId := AJson.GetValue<string>('tvgId', '');
  Result.TvgName := AJson.GetValue<string>('tvgName', '');
  Result.UpstreamUrl := AJson.GetValue<string>('upstreamUrl', '');
end;

function ExportStoreSettings(const AStore: IStore): TJSONObject;
var
  lSources: TObjectList<TSourceConfig>;
  lLists: TObjectList<TCustomList>;
  lGroups: TCustomGroupList;
  lItems: TCustomItemList;
  lSource: TSourceConfig;
  lList: TCustomList;
  lGroup: TCustomGroup;
  lItem: TCustomItem;
  lStream: TStreamItem;
  lSrcArr, lListArr, lGrpArr, lItemArr: TJSONArray;
  lListObj, lItemObj: TJSONObject;
  lSrcNames, lGrpNames: TDictionary<Integer, string>;
  lGName: string;
begin
  Result := TJSONObject.Create;
  Result.AddPair('version', TJSONNumber.Create(cBundleVersion));

  lSrcNames := TDictionary<Integer, string>.Create;
  try
    lSrcArr := TJSONArray.Create;
    lSources := AStore.LoadSources;
    try
      for lSource in lSources do
      begin
        lSrcArr.Add(SourceToJson(lSource));
        lSrcNames.AddOrSetValue(lSource.Id, lSource.Name);
      end;
    finally
      FreeAndNil(lSources);
    end;
    Result.AddPair('sources', lSrcArr);

    lListArr := TJSONArray.Create;
    lLists := AStore.LoadLists;
    try
      for lList in lLists do
      begin
        lListObj := ListToJson(lList);
        lGrpArr := TJSONArray.Create;
        lGrpNames := TDictionary<Integer, string>.Create;
        try
          lGroups := AStore.LoadGroups(lList.Id);
          try
            for lGroup in lGroups do
            begin
              lGrpArr.Add(GroupToJson(lGroup));
              lGrpNames.AddOrSetValue(lGroup.Id, lGroup.Name);
            end;
          finally
            FreeAndNil(lGroups);
          end;
          lListObj.AddPair('groups', lGrpArr);

          lItemArr := TJSONArray.Create;
          lItems := AStore.LoadItems(lList.Id);
          try
            for lItem in lItems do
            begin
              lStream := AStore.LoadStreamById(lItem.StreamItemId);
              if lStream = nil then
                Continue;
              try
                lItemObj := TJSONObject.Create;
                lItemObj.AddPair('displayName', lItem.DisplayName);
                lItemObj.AddPair('logoOverride', lItem.LogoOverride);
                lItemObj.AddPair('tvgIdOverride', lItem.TvgIdOverride);
                lItemObj.AddPair('channelNumber', TJSONNumber.Create(lItem.ChannelNumber));
                if (lItem.CustomGroupId <> 0) and lGrpNames.TryGetValue(lItem.CustomGroupId, lGName) then
                  lItemObj.AddPair('groupName', lGName)
                else
                  lItemObj.AddPair('groupName', '');
                if not lSrcNames.TryGetValue(lStream.SourceId, lGName) then
                  lGName := '';
                lItemObj.AddPair('stream', StreamExportJson(lGName, lStream));
                lItemArr.Add(lItemObj);
              finally
                FreeAndNil(lStream);
              end;
            end;
          finally
            FreeAndNil(lItems);
          end;
          lListObj.AddPair('items', lItemArr);
        finally
          FreeAndNil(lGrpNames);
        end;
        lListArr.Add(lListObj);
      end;
    finally
      FreeAndNil(lLists);
    end;
    Result.AddPair('lists', lListArr);
  finally
    FreeAndNil(lSrcNames);
  end;
end;

function ImportStoreSettings(const AStore: IStore; const ABody: TJSONObject): TImportCounts;
var
  lExisting: TObjectList<TSourceConfig>;
  lExistingLists: TObjectList<TCustomList>;
  lAllStreams: TStreamItemList;
  lStream: TStreamItem;
  lSource: TSourceConfig;
  lList: TCustomList;
  lGroup: TCustomGroup;
  lItem: TCustomItem;
  lValue, lGroupValue, lItemValue: TJSONValue;
  lStreamObj: TJSONObject;
  lNewListId, lNewSrcId, lStreamId, lGroupId: Integer;
  lGrpOrder: TList<Integer>;
  lSrcIdByName, lGrpIdByName, lStreamIdByUrl: TDictionary<string, Integer>;
  lSnaps: TObjectDictionary<string, TSourceSnapshot>;
  lSeenStream: TDictionary<string, Boolean>;
  lSrcName, lUrl, lGName, lKey: string;
  lSnap: TSourceSnapshot;
  lFilter: TCatalogFilter;
begin
  Result := Default(TImportCounts);

  lSrcIdByName := nil;
  lStreamIdByUrl := nil;
  lSnaps := nil;
  lSeenStream := nil;
  try
    lSrcIdByName := TDictionary<string, Integer>.Create;
    lStreamIdByUrl := TDictionary<string, Integer>.Create;
    lSnaps := TObjectDictionary<string, TSourceSnapshot>.Create([doOwnsValues]);
    lSeenStream := TDictionary<string, Boolean>.Create;
    // wipe: lists first (drops items + groups), then sources (drops catalog/EPG)
    lExistingLists := AStore.LoadLists;
    try
      for lList in lExistingLists do
        AStore.DeleteList(lList.Id);
    finally
      FreeAndNil(lExistingLists);
    end;
    lExisting := AStore.LoadSources;
    try
      for lSource in lExisting do
        AStore.DeleteSource(lSource.Id);
    finally
      FreeAndNil(lExisting);
    end;

    // 1) recreate sources, remember name -> new id
    if ABody.GetValue('sources') is TJSONArray then
      for lValue in TJSONArray(ABody.GetValue('sources')) do
        if lValue is TJSONObject then
        begin
          lSource := TSourceConfig.Create;
          try
            SourceFromJson(TJSONObject(lValue), lSource);
            lSource.Id := 0;
            lNewSrcId := AStore.SaveSource(lSource);
            lSrcIdByName.AddOrSetValue(lSource.Name, lNewSrcId);
            Inc(Result.Sources);
          finally
            FreeAndNil(lSource);
          end;
        end;

    // 2) gather every chosen channel's stream (deduped) into a per-source snapshot
    if ABody.GetValue('lists') is TJSONArray then
      for lValue in TJSONArray(ABody.GetValue('lists')) do
        if (lValue is TJSONObject) and (TJSONObject(lValue).GetValue('items') is TJSONArray) then
          for lItemValue in TJSONArray(TJSONObject(lValue).GetValue('items')) do
            if (lItemValue is TJSONObject) and (TJSONObject(lItemValue).GetValue('stream') is TJSONObject) then
            begin
              lStreamObj := TJSONObject(TJSONObject(lItemValue).GetValue('stream'));
              lSrcName := lStreamObj.GetValue<string>('sourceName', '');
              if not lSrcIdByName.TryGetValue(lSrcName, lNewSrcId) then
                Continue;
              lKey := lSrcName + cStreamKeySep + lStreamObj.GetValue<string>('contentType', '') + cStreamKeySep +
                     lStreamObj.GetValue<string>('upstreamId', '') + cStreamKeySep +
                     lStreamObj.GetValue<string>('upstreamUrl', '');
              if lSeenStream.ContainsKey(lKey) then
                Continue;
              lSeenStream.Add(lKey, True);
              if not lSnaps.TryGetValue(lSrcName, lSnap) then
              begin
                lSnap := TSourceSnapshot.Create(lNewSrcId);
                lSnaps.Add(lSrcName, lSnap);
              end;
              lSnap.Streams.Add(StreamFromExportJson(lStreamObj, lNewSrcId));
            end;

    // 3) merge those streams into the catalog, then map upstream URL -> new id
    for lSnap in lSnaps.Values do
      AStore.MergeSnapshot(lSnap);
    lFilter := Default(TCatalogFilter);
    lAllStreams := AStore.LoadStreams(lFilter);
    try
      for lStream in lAllStreams do
        lStreamIdByUrl.AddOrSetValue(lStream.UpstreamUrl, lStream.Id);
    finally
      FreeAndNil(lAllStreams);
    end;

    // 4) recreate lists + groups + items
    if ABody.GetValue('lists') is TJSONArray then
      for lValue in TJSONArray(ABody.GetValue('lists')) do
        if lValue is TJSONObject then
        begin
          lList := TCustomList.Create;
          try
            ListFromJson(TJSONObject(lValue), lList);
            lList.Id := 0;
            lNewListId := AStore.SaveList(lList);
            Inc(Result.Lists);
          finally
            FreeAndNil(lList);
          end;

          lGrpIdByName := nil;
          lGrpOrder := nil;
          try
            lGrpIdByName := TDictionary<string, Integer>.Create;
            lGrpOrder := TList<Integer>.Create;
            if TJSONObject(lValue).GetValue('groups') is TJSONArray then
              for lGroupValue in TJSONArray(TJSONObject(lValue).GetValue('groups')) do
                if lGroupValue is TJSONObject then
                begin
                  lGroup := TCustomGroup.Create;
                  try
                    GroupFromJson(TJSONObject(lGroupValue), lGroup);
                    lGroup.Id := 0;
                    lGroup.ListId := lNewListId;
                    lGroupId := AStore.SaveGroup(lGroup);
                    lGrpIdByName.AddOrSetValue(lGroup.Name, lGroupId);
                    lGrpOrder.Add(lGroupId);
                    Inc(Result.Groups);
                  finally
                    FreeAndNil(lGroup);
                  end;
                end;
            // SaveGroup doesn't persist sort_order (only ReorderGroups does), so the
            // manual group order would be lost on import. The export writes groups in
            // display order (favorites first, then sort_order), so re-applying that
            // array order via ReorderGroups restores the operator's arrangement.
            if lGrpOrder.Count > 0 then
              AStore.ReorderGroups(lNewListId, lGrpOrder.ToArray);

            if TJSONObject(lValue).GetValue('items') is TJSONArray then
              for lItemValue in TJSONArray(TJSONObject(lValue).GetValue('items')) do
                if (lItemValue is TJSONObject) and (TJSONObject(lItemValue).GetValue('stream') is TJSONObject) then
                begin
                  lStreamObj := TJSONObject(TJSONObject(lItemValue).GetValue('stream'));
                  lUrl := lStreamObj.GetValue<string>('upstreamUrl', '');
                  if not lStreamIdByUrl.TryGetValue(lUrl, lStreamId) then
                    Continue;
                  lItem := TCustomItem.Create;
                  try
                    lItem.Id := 0;
                    lItem.ListId := lNewListId;
                    lItem.StreamItemId := lStreamId;
                    lItem.ContentType := ContentTypeFromString(
                      lStreamObj.GetValue<string>('contentType', ContentTypeNames[ctLive]));
                    lItem.DisplayName := TJSONObject(lItemValue).GetValue<string>('displayName', '');
                    lItem.LogoOverride := TJSONObject(lItemValue).GetValue<string>('logoOverride', '');
                    lItem.TvgIdOverride := TJSONObject(lItemValue).GetValue<string>('tvgIdOverride', '');
                    lItem.ChannelNumber := TJSONObject(lItemValue).GetValue<Integer>('channelNumber', 0);
                    lGName := TJSONObject(lItemValue).GetValue<string>('groupName', '');
                    if (lGName <> '') and lGrpIdByName.TryGetValue(lGName, lGroupId) then
                      lItem.CustomGroupId := lGroupId
                    else
                      lItem.CustomGroupId := 0;
                    AStore.SaveItem(lItem);
                    Inc(Result.Items);
                  finally
                    FreeAndNil(lItem);
                  end;
                end;
          finally
            FreeAndNil(lGrpIdByName);
            FreeAndNil(lGrpOrder);
          end;
        end;
  finally
    FreeAndNil(lSrcIdByName);
    FreeAndNil(lStreamIdByUrl);
    FreeAndNil(lSnaps);
    FreeAndNil(lSeenStream);
  end;
end;

end.
