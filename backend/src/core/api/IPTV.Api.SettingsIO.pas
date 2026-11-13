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
  System.JSON,
  IPTV.Storage.Intf;

type
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
  System.Generics.Collections,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.CustomList,
  IPTV.Api.Serializers;

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

function StreamFromExportJson(const J: TJSONObject; ASourceId: Integer): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.SourceId := ASourceId;
  Result.ContentType := ContentTypeFromString(J.GetValue<string>('contentType', 'live'));
  Result.UpstreamId := J.GetValue<string>('upstreamId', '');
  Result.Name := J.GetValue<string>('name', '');
  Result.Logo := J.GetValue<string>('logo', '');
  Result.GroupTitle := J.GetValue<string>('groupTitle', '');
  Result.CategoryUpstreamId := J.GetValue<string>('categoryUpstreamId', '');
  Result.TvgId := J.GetValue<string>('tvgId', '');
  Result.TvgName := J.GetValue<string>('tvgName', '');
  Result.UpstreamUrl := J.GetValue<string>('upstreamUrl', '');
end;

function ExportStoreSettings(const AStore: IStore): TJSONObject;
var
  Sources: TObjectList<TSourceConfig>;
  Lists: TObjectList<TCustomList>;
  Groups: TCustomGroupList;
  Items: TCustomItemList;
  S: TSourceConfig;
  L: TCustomList;
  G: TCustomGroup;
  It: TCustomItem;
  Stream: TStreamItem;
  SrcArr, ListArr, GrpArr, ItemArr: TJSONArray;
  LObj, ItObj: TJSONObject;
  SrcNames, GrpNames: TDictionary<Integer, string>;
  GName: string;
begin
  Result := TJSONObject.Create;
  Result.AddPair('version', TJSONNumber.Create(1));

  SrcNames := TDictionary<Integer, string>.Create;
  try
    SrcArr := TJSONArray.Create;
    Sources := AStore.LoadSources;
    try
      for S in Sources do
      begin
        SrcArr.Add(SourceToJson(S));
        SrcNames.AddOrSetValue(S.Id, S.Name);
      end;
    finally
      Sources.Free;
    end;
    Result.AddPair('sources', SrcArr);

    ListArr := TJSONArray.Create;
    Lists := AStore.LoadLists;
    try
      for L in Lists do
      begin
        LObj := ListToJson(L);
        GrpArr := TJSONArray.Create;
        GrpNames := TDictionary<Integer, string>.Create;
        try
          Groups := AStore.LoadGroups(L.Id);
          try
            for G in Groups do
            begin
              GrpArr.Add(GroupToJson(G));
              GrpNames.AddOrSetValue(G.Id, G.Name);
            end;
          finally
            Groups.Free;
          end;
          LObj.AddPair('groups', GrpArr);

          ItemArr := TJSONArray.Create;
          Items := AStore.LoadItems(L.Id);
          try
            for It in Items do
            begin
              Stream := AStore.LoadStreamById(It.StreamItemId);
              if Stream = nil then
                Continue;
              try
                ItObj := TJSONObject.Create;
                ItObj.AddPair('displayName', It.DisplayName);
                ItObj.AddPair('logoOverride', It.LogoOverride);
                ItObj.AddPair('tvgIdOverride', It.TvgIdOverride);
                ItObj.AddPair('channelNumber', TJSONNumber.Create(It.ChannelNumber));
                if (It.CustomGroupId <> 0) and GrpNames.TryGetValue(It.CustomGroupId, GName) then
                  ItObj.AddPair('groupName', GName)
                else
                  ItObj.AddPair('groupName', '');
                if not SrcNames.TryGetValue(Stream.SourceId, GName) then
                  GName := '';
                ItObj.AddPair('stream', StreamExportJson(GName, Stream));
                ItemArr.Add(ItObj);
              finally
                Stream.Free;
              end;
            end;
          finally
            Items.Free;
          end;
          LObj.AddPair('items', ItemArr);
        finally
          GrpNames.Free;
        end;
        ListArr.Add(LObj);
      end;
    finally
      Lists.Free;
    end;
    Result.AddPair('lists', ListArr);
  finally
    SrcNames.Free;
  end;
end;

function ImportStoreSettings(const AStore: IStore; const ABody: TJSONObject): TImportCounts;
var
  Existing: TObjectList<TSourceConfig>;
  ExistingLists: TObjectList<TCustomList>;
  AllStreams: TStreamItemList;
  St: TStreamItem;
  S: TSourceConfig;
  L: TCustomList;
  G: TCustomGroup;
  Item: TCustomItem;
  V, GV, IV: TJSONValue;
  SObj: TJSONObject;
  NewListId, NewSrcId, Sid, GId: Integer;
  GrpOrder: TList<Integer>;
  SrcIdByName, GrpIdByName, StreamIdByUrl: TDictionary<string, Integer>;
  Snaps: TObjectDictionary<string, TSourceSnapshot>;
  SeenStream: TDictionary<string, Boolean>;
  SName, Url, GName, Key: string;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Result := Default(TImportCounts);

  SrcIdByName := TDictionary<string, Integer>.Create;
  StreamIdByUrl := TDictionary<string, Integer>.Create;
  Snaps := TObjectDictionary<string, TSourceSnapshot>.Create([doOwnsValues]);
  SeenStream := TDictionary<string, Boolean>.Create;
  try
    // wipe: lists first (drops items + groups), then sources (drops catalog/EPG)
    ExistingLists := AStore.LoadLists;
    try
      for L in ExistingLists do AStore.DeleteList(L.Id);
    finally
      ExistingLists.Free;
    end;
    Existing := AStore.LoadSources;
    try
      for S in Existing do AStore.DeleteSource(S.Id);
    finally
      Existing.Free;
    end;

    // 1) recreate sources, remember name -> new id
    if ABody.GetValue('sources') is TJSONArray then
      for V in TJSONArray(ABody.GetValue('sources')) do
        if V is TJSONObject then
        begin
          S := TSourceConfig.Create;
          try
            SourceFromJson(TJSONObject(V), S);
            S.Id := 0;
            NewSrcId := AStore.SaveSource(S);
            SrcIdByName.AddOrSetValue(S.Name, NewSrcId);
            Inc(Result.Sources);
          finally
            S.Free;
          end;
        end;

    // 2) gather every chosen channel's stream (deduped) into a per-source snapshot
    if ABody.GetValue('lists') is TJSONArray then
      for V in TJSONArray(ABody.GetValue('lists')) do
        if (V is TJSONObject) and (TJSONObject(V).GetValue('items') is TJSONArray) then
          for IV in TJSONArray(TJSONObject(V).GetValue('items')) do
            if (IV is TJSONObject) and (TJSONObject(IV).GetValue('stream') is TJSONObject) then
            begin
              SObj := TJSONObject(TJSONObject(IV).GetValue('stream'));
              SName := SObj.GetValue<string>('sourceName', '');
              if not SrcIdByName.TryGetValue(SName, NewSrcId) then
                Continue;
              Key := SName + '|' + SObj.GetValue<string>('contentType', '') + '|' +
                     SObj.GetValue<string>('upstreamId', '') + '|' +
                     SObj.GetValue<string>('upstreamUrl', '');
              if SeenStream.ContainsKey(Key) then
                Continue;
              SeenStream.Add(Key, True);
              if not Snaps.TryGetValue(SName, Snap) then
              begin
                Snap := TSourceSnapshot.Create(NewSrcId);
                Snaps.Add(SName, Snap);
              end;
              Snap.Streams.Add(StreamFromExportJson(SObj, NewSrcId));
            end;

    // 3) merge those streams into the catalog, then map upstream URL -> new id
    for Snap in Snaps.Values do
      AStore.MergeSnapshot(Snap);
    F := Default(TCatalogFilter);
    AllStreams := AStore.LoadStreams(F);
    try
      for St in AllStreams do
        StreamIdByUrl.AddOrSetValue(St.UpstreamUrl, St.Id);
    finally
      AllStreams.Free;
    end;

    // 4) recreate lists + groups + items
    if ABody.GetValue('lists') is TJSONArray then
      for V in TJSONArray(ABody.GetValue('lists')) do
        if V is TJSONObject then
        begin
          L := TCustomList.Create;
          try
            ListFromJson(TJSONObject(V), L);
            L.Id := 0;
            NewListId := AStore.SaveList(L);
            Inc(Result.Lists);
          finally
            L.Free;
          end;

          GrpIdByName := TDictionary<string, Integer>.Create;
          GrpOrder := TList<Integer>.Create;
          try
            if TJSONObject(V).GetValue('groups') is TJSONArray then
              for GV in TJSONArray(TJSONObject(V).GetValue('groups')) do
                if GV is TJSONObject then
                begin
                  G := TCustomGroup.Create;
                  try
                    GroupFromJson(TJSONObject(GV), G);
                    G.Id := 0;
                    G.ListId := NewListId;
                    GId := AStore.SaveGroup(G);
                    GrpIdByName.AddOrSetValue(G.Name, GId);
                    GrpOrder.Add(GId);
                    Inc(Result.Groups);
                  finally
                    G.Free;
                  end;
                end;
            // SaveGroup doesn't persist sort_order (only ReorderGroups does), so the
            // manual group order would be lost on import. The export writes groups in
            // display order (favorites first, then sort_order), so re-applying that
            // array order via ReorderGroups restores the operator's arrangement.
            if GrpOrder.Count > 0 then
              AStore.ReorderGroups(NewListId, GrpOrder.ToArray);

            if TJSONObject(V).GetValue('items') is TJSONArray then
              for IV in TJSONArray(TJSONObject(V).GetValue('items')) do
                if (IV is TJSONObject) and (TJSONObject(IV).GetValue('stream') is TJSONObject) then
                begin
                  SObj := TJSONObject(TJSONObject(IV).GetValue('stream'));
                  Url := SObj.GetValue<string>('upstreamUrl', '');
                  if not StreamIdByUrl.TryGetValue(Url, Sid) then
                    Continue;
                  Item := TCustomItem.Create;
                  try
                    Item.Id := 0;
                    Item.ListId := NewListId;
                    Item.StreamItemId := Sid;
                    Item.ContentType := ContentTypeFromString(SObj.GetValue<string>('contentType', 'live'));
                    Item.DisplayName := TJSONObject(IV).GetValue<string>('displayName', '');
                    Item.LogoOverride := TJSONObject(IV).GetValue<string>('logoOverride', '');
                    Item.TvgIdOverride := TJSONObject(IV).GetValue<string>('tvgIdOverride', '');
                    Item.ChannelNumber := TJSONObject(IV).GetValue<Integer>('channelNumber', 0);
                    GName := TJSONObject(IV).GetValue<string>('groupName', '');
                    if (GName <> '') and GrpIdByName.TryGetValue(GName, GId) then
                      Item.CustomGroupId := GId
                    else
                      Item.CustomGroupId := 0;
                    AStore.SaveItem(Item);
                    Inc(Result.Items);
                  finally
                    Item.Free;
                  end;
                end;
          finally
            GrpIdByName.Free;
            GrpOrder.Free;
          end;
        end;
  finally
    SrcIdByName.Free;
    StreamIdByUrl.Free;
    Snaps.Free;
    SeenStream.Free;
  end;
end;

end.
