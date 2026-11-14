unit Test.Serializers;

{ Round-trip tests for IPTV.Api.Serializers (model <-> JSON, camelCase). }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Model &lt;-&gt; JSON round-trip and partial-patch tests.</summary>
  [TestFixture]
  TSerializerTests = class
  public
    /// <summary>A source config round-trips through JSON.</summary>
    [Test] procedure SourceRoundtrip;
    /// <summary>A list round-trips through JSON.</summary>
    [Test] procedure ListRoundtrip;
    /// <summary>A list item round-trips through JSON.</summary>
    [Test] procedure ItemRoundtrip;
    /// <summary>IntArrayFromJson parses an id array (missing key = empty).</summary>
    [Test] procedure IntArrayFromJsonParses;
    /// <summary>A partial favorite patch keeps the group name.</summary>
    [Test] procedure GroupPartialPatchKeepsName;
    /// <summary>A partial rename keeps the favorite flag.</summary>
    [Test] procedure GroupPartialRenameKeepsFavorite;
    /// <summary>A partial source patch keeps the other fields.</summary>
    [Test] procedure SourcePartialPatchKeepsFields;
    /// <summary>A partial list patch keeps the other fields.</summary>
    [Test] procedure ListPartialPatchKeepsFields;
    /// <summary>A partial item patch keeps the other fields.</summary>
    [Test] procedure ItemPartialPatchKeepsFields;
    /// <summary>Source password: missing or '' keeps it, a value sets it, clearPassword clears it.</summary>
    [Test] procedure SourcePasswordEmptyKeeps;
    /// <summary>Mirror credential rows follow the same password contract per row.</summary>
    [Test] procedure MirrorPasswordEmptyKeeps;
    /// <summary>The admin JSON masks secret query values of url and epgUrl.</summary>
    [Test] procedure SourceAdminJsonMasksUrlSecrets;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.JSON,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.CustomList,
  IPTV.Api.Serializers;

procedure TSerializerTests.SourceRoundtrip;
var
  lOriginal: TSourceConfig;
  lCopy: TSourceConfig;
  lJson: TJSONObject;
begin
  lOriginal := nil;
  lCopy := nil;
  try
    lOriginal := TSourceConfig.Create;
    lCopy := TSourceConfig.Create;
    lOriginal.Id := 7;
    lOriginal.Name := 'P';
    lOriginal.Kind := skM3U;
    lOriginal.Url := 'http://x/p.m3u';
    lOriginal.Enabled := False;
    lOriginal.ContentTypes := [ctLive, ctRadio];
    lOriginal.StripPrefixes := ['NL', 'UK'];
    lOriginal.ForceHls := True;
    lJson := SourceToJson(lOriginal);
    try
      SourceFromJson(lJson, lCopy);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual(7, lCopy.Id);
    Assert.AreEqual('P', lCopy.Name);
    Assert.AreEqual(skM3U, lCopy.Kind);
    Assert.IsFalse(lCopy.Enabled);
    Assert.IsTrue([ctLive, ctRadio] = lCopy.ContentTypes);
    Assert.AreEqual<Integer>(2, Length(lCopy.StripPrefixes), 'stripPrefixes round-trip');
    Assert.AreEqual('UK', lCopy.StripPrefixes[1]);
    Assert.IsTrue(lCopy.ForceHls, 'forceHls round-trips');
  finally
    FreeAndNil(lOriginal);
    FreeAndNil(lCopy);
  end;
end;

procedure TSerializerTests.ListRoundtrip;
var
  lOriginal: TCustomList;
  lCopy: TCustomList;
  lJson: TJSONObject;
begin
  lOriginal := nil;
  lCopy := nil;
  try
    lOriginal := TCustomList.Create;
    lCopy := TCustomList.Create;
    lOriginal.Id := 3;
    lOriginal.Name := 'List';
    lOriginal.OutputUsername := '';
    lOriginal.OutputPassword := '';
    lOriginal.Enabled := True;
    lJson := ListToJson(lOriginal);
    try
      ListFromJson(lJson, lCopy);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual(3, lCopy.Id);
    Assert.AreEqual('List', lCopy.Name);
    Assert.AreEqual('', lCopy.OutputUsername, 'optional credentials round-trip as empty');
    Assert.IsTrue(lCopy.Enabled);
  finally
    FreeAndNil(lOriginal);
    FreeAndNil(lCopy);
  end;
end;

procedure TSerializerTests.ItemRoundtrip;
var
  lOriginal: TCustomItem;
  lCopy: TCustomItem;
  lJson: TJSONObject;
begin
  lOriginal := nil;
  lCopy := nil;
  try
    lOriginal := TCustomItem.Create;
    lCopy := TCustomItem.Create;
    lOriginal.Id := 1;
    lOriginal.ListId := 2;
    lOriginal.StreamItemId := 9;
    lOriginal.CustomGroupId := 4;
    lOriginal.DisplayName := 'Renamed';
    lOriginal.ChannelNumber := 42;
    lJson := ItemToJson(lOriginal);
    try
      ItemFromJson(lJson, lCopy);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual(9, lCopy.StreamItemId);
    Assert.AreEqual(4, lCopy.CustomGroupId);
    Assert.AreEqual('Renamed', lCopy.DisplayName);
    Assert.AreEqual(42, lCopy.ChannelNumber);
  finally
    FreeAndNil(lOriginal);
    FreeAndNil(lCopy);
  end;
end;

procedure TSerializerTests.IntArrayFromJsonParses;
var
  lJson: TJSONObject;
  lIds: TArray<Integer>;
begin
  lJson := TJSONObject(TJSONObject.ParseJSONValue('{"ids":[3,5,8]}'));
  try
    lIds := IntArrayFromJson(lJson, 'ids');
    Assert.AreEqual<Integer>(3, Length(lIds));
    Assert.AreEqual(8, lIds[2]);
    // missing key -> empty array
    Assert.AreEqual<Integer>(0, Length(IntArrayFromJson(lJson, 'missing')));
  finally
    FreeAndNil(lJson);
  end;
end;

// Regression: the favorite-star / rename send a PARTIAL group patch. The API
// loads the existing group then merges, and GroupFromJson must only override the
// keys actually present — never blank the others. (Bug: star wiped the name.)
procedure TSerializerTests.GroupPartialPatchKeepsName;
var
  lGroup: TCustomGroup;
  lJson: TJSONObject;
begin
  lGroup := TCustomGroup.Create;
  try
    lGroup.Id := 10;
    lGroup.Name := 'Sport';
    lGroup.ContentType := ctLive;
    lGroup.IsFavorite := False;
    lJson := TJSONObject.Create;
    try
      lJson.AddPair('id', TJSONNumber.Create(10));
      lJson.AddPair('isFavorite', TJSONBool.Create(True)); // favorite star: only id + isFavorite
      GroupFromJson(lJson, lGroup);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual('Sport', lGroup.Name, 'name preserved by a partial favorite toggle');
    Assert.IsTrue(lGroup.IsFavorite, 'favorite flag applied');
    Assert.AreEqual(ctLive, lGroup.ContentType, 'content type preserved');
  finally
    FreeAndNil(lGroup);
  end;
end;

procedure TSerializerTests.GroupPartialRenameKeepsFavorite;
var
  lGroup: TCustomGroup;
  lJson: TJSONObject;
begin
  lGroup := TCustomGroup.Create;
  try
    lGroup.Id := 10;
    lGroup.Name := 'Sport';
    lGroup.IsFavorite := True;
    lJson := TJSONObject.Create;
    try
      lJson.AddPair('id', TJSONNumber.Create(10));
      lJson.AddPair('name', 'News'); // rename: only id + name
      GroupFromJson(lJson, lGroup);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual('News', lGroup.Name);
    Assert.IsTrue(lGroup.IsFavorite, 'favorite preserved by a partial rename');
  finally
    FreeAndNil(lGroup);
  end;
end;

procedure TSerializerTests.SourcePartialPatchKeepsFields;
var
  lSource: TSourceConfig;
  lJson: TJSONObject;
begin
  lSource := TSourceConfig.Create;
  try
    lSource.Id := 7;
    lSource.Name := 'P';
    lSource.Url := 'http://x';
    lSource.Username := 'u';
    lSource.Password := 'pw';
    lJson := TJSONObject.Create;
    try
      lJson.AddPair('id', TJSONNumber.Create(7));
      lJson.AddPair('enabled', TJSONBool.Create(False)); // partial: only id + enabled
      SourceFromJson(lJson, lSource);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual('P', lSource.Name, 'name preserved by a partial patch');
    Assert.AreEqual('http://x', lSource.Url, 'url preserved');
    Assert.AreEqual('u', lSource.Username, 'username preserved');
    Assert.IsFalse(lSource.Enabled, 'enabled applied');
  finally
    FreeAndNil(lSource);
  end;
end;

procedure TSerializerTests.ListPartialPatchKeepsFields;
var
  lList: TCustomList;
  lJson: TJSONObject;
begin
  lList := TCustomList.Create;
  try
    lList.Id := 3;
    lList.Name := 'Box';
    lList.OutputUsername := 'bu';
    lList.OutputPassword := 'bp';
    lList.Enabled := True;
    lJson := TJSONObject.Create;
    try
      lJson.AddPair('id', TJSONNumber.Create(3));
      lJson.AddPair('enabled', TJSONBool.Create(False));
      ListFromJson(lJson, lList);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual('Box', lList.Name);
    Assert.AreEqual('bu', lList.OutputUsername, 'output credentials preserved by a partial patch');
    Assert.AreEqual('bp', lList.OutputPassword);
    Assert.IsFalse(lList.Enabled);
  finally
    FreeAndNil(lList);
  end;
end;

procedure TSerializerTests.ItemPartialPatchKeepsFields;
var
  lItem: TCustomItem;
  lJson: TJSONObject;
begin
  lItem := TCustomItem.Create;
  try
    lItem.Id := 1;
    lItem.StreamItemId := 9;
    lItem.CustomGroupId := 4;
    lItem.ChannelNumber := 42;
    lItem.DisplayName := 'Old';
    lJson := TJSONObject.Create;
    try
      lJson.AddPair('id', TJSONNumber.Create(1));
      lJson.AddPair('displayName', 'New'); // partial: only id + displayName
      ItemFromJson(lJson, lItem);
    finally
      FreeAndNil(lJson);
    end;
    Assert.AreEqual('New', lItem.DisplayName);
    Assert.AreEqual(9, lItem.StreamItemId, 'stream link preserved');
    Assert.AreEqual(4, lItem.CustomGroupId, 'group preserved (not reset to upstream)');
    Assert.AreEqual(42, lItem.ChannelNumber, 'channel number preserved (not reset to 0)');
  finally
    FreeAndNil(lItem);
  end;
end;

procedure TSerializerTests.SourcePasswordEmptyKeeps;
var
  lSource: TSourceConfig;
  lBody: TJSONObject;
begin
  lBody := nil;
  lSource := TSourceConfig.Create;
  try
    lSource.Password := 'secret';
    lBody := TJSONObject.Create.AddPair('name', 'renamed');
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('secret', lSource.Password, 'no key = keep');
    FreeAndNil(lBody);
    lBody := TJSONObject.Create.AddPair('password', '');
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('secret', lSource.Password, 'an empty value = keep (the GET always sends "")');
    FreeAndNil(lBody);
    lBody := TJSONObject.Create.AddPair('password', 'new');
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('new', lSource.Password, 'a value sets it');
    FreeAndNil(lBody);
    lBody := TJSONObject.Create.AddPair('password', '').AddPair('clearPassword', TJSONBool.Create(True));
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('', lSource.Password, 'clearPassword clears it');
    FreeAndNil(lBody);
    lBody := TJSONObject.Create.AddPair('password', 'x').AddPair('clearPassword', TJSONBool.Create(True));
    SourceFromJson(lBody, lSource);
    Assert.AreEqual('', lSource.Password, 'clearPassword wins over a value');
  finally
    FreeAndNil(lBody);
    FreeAndNil(lSource);
  end;
end;

procedure TSerializerTests.MirrorPasswordEmptyKeeps;
const
  cMissing = 1;
  cEmpty = 2;
  cSet = 3;
  cCleared = 4;
  cUnknown = 5;
var
  lStored: TArray<TMirrorCredential>;
  lParsed: TArray<TMirrorCredential>;
  lArray: TJSONArray;
  i: Integer;
begin
  SetLength(lStored, 4);
  for i := 0 to High(lStored) do
  begin
    lStored[i].SourceId := i + 1;
    lStored[i].Password := 'old' + IntToStr(i + 1);
  end;
  lArray := TJSONArray.Create;
  try
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cMissing)));
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cEmpty))
      .AddPair('password', ''));
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cSet))
      .AddPair('password', 'new3'));
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cCleared))
      .AddPair('password', '').AddPair('clearPassword', TJSONBool.Create(True)));
    lArray.AddElement(TJSONObject.Create.AddPair('sourceId', TJSONNumber.Create(cUnknown))
      .AddPair('password', ''));
    lParsed := MirrorCredentialsFromJson(lArray, lStored);
  finally
    FreeAndNil(lArray);
  end;
  Assert.AreEqual(5, Length(lParsed));
  Assert.AreEqual('old1', lParsed[0].Password, 'no key = the stored password');
  Assert.AreEqual('old2', lParsed[1].Password, 'empty = the stored password');
  Assert.AreEqual('new3', lParsed[2].Password, 'a value sets it');
  Assert.AreEqual('', lParsed[3].Password, 'clearPassword clears it');
  Assert.AreEqual('', lParsed[4].Password, 'nothing stored for that source: stays empty');
end;

procedure TSerializerTests.SourceAdminJsonMasksUrlSecrets;
var
  lSource: TSourceConfig;
  lJson: TJSONObject;
begin
  lJson := nil;
  lSource := TSourceConfig.Create;
  try
    lSource.Url := 'http://p:8080/get.php?username=u&password=pw&type=m3u_plus';
    lSource.EpgUrl := 'http://g/xmltv.php?token=abc';
    lJson := SourceToAdminJson(lSource);
    Assert.AreEqual('http://p:8080/get.php?username=u&password=***&type=m3u_plus', lJson.GetValue<string>('url'));
    Assert.AreEqual('http://g/xmltv.php?token=***', lJson.GetValue<string>('epgUrl'));
    FreeAndNil(lJson);
    // the export / backup form stays complete
    lJson := SourceToJson(lSource);
    Assert.AreEqual(lSource.Url, lJson.GetValue<string>('url'), 'export keeps the real URL');
  finally
    FreeAndNil(lJson);
    FreeAndNil(lSource);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);

end.
