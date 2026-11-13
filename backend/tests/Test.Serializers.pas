unit Test.Serializers;

{ Round-trip tests for IPTV.Api.Serializers (model <-> JSON, camelCase). }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSerializerTests = class
  public
    [Test] procedure SourceRoundtrip;
    [Test] procedure ListRoundtrip;
    [Test] procedure ItemRoundtrip;
    [Test] procedure IntArrayFromJsonParses;
    [Test] procedure GroupPartialPatchKeepsName;
    [Test] procedure GroupPartialRenameKeepsFavorite;
    [Test] procedure SourcePartialPatchKeepsFields;
    [Test] procedure ListPartialPatchKeepsFields;
    [Test] procedure ItemPartialPatchKeepsFields;
  end;

implementation

uses
  System.JSON,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.CustomList, IPTV.Api.Serializers;

procedure TSerializerTests.SourceRoundtrip;
var
  A, B: TSourceConfig;
  J: TJSONObject;
begin
  A := TSourceConfig.Create;
  B := TSourceConfig.Create;
  try
    A.Id := 7; A.Name := 'P'; A.Kind := skM3U; A.Url := 'http://x/p.m3u';
    A.Enabled := False; A.ContentTypes := [ctLive, ctRadio];
    A.StripPrefixes := ['NL', 'UK'];
    A.ForceHls := True;
    J := SourceToJson(A);
    try
      SourceFromJson(J, B);
    finally
      J.Free;
    end;
    Assert.AreEqual(7, B.Id);
    Assert.AreEqual('P', B.Name);
    Assert.AreEqual(skM3U, B.Kind);
    Assert.IsFalse(B.Enabled);
    Assert.IsTrue([ctLive, ctRadio] = B.ContentTypes);
    Assert.AreEqual<Integer>(2, Length(B.StripPrefixes), 'stripPrefixes round-trip');
    Assert.AreEqual('UK', B.StripPrefixes[1]);
    Assert.IsTrue(B.ForceHls, 'forceHls round-trips');
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TSerializerTests.ListRoundtrip;
var
  A, B: TCustomList;
  J: TJSONObject;
begin
  A := TCustomList.Create;
  B := TCustomList.Create;
  try
    A.Id := 3; A.Name := 'List'; A.OutputUsername := ''; A.OutputPassword := ''; A.Enabled := True;
    J := ListToJson(A);
    try
      ListFromJson(J, B);
    finally
      J.Free;
    end;
    Assert.AreEqual(3, B.Id);
    Assert.AreEqual('List', B.Name);
    Assert.AreEqual('', B.OutputUsername, 'optional credentials round-trip as empty');
    Assert.IsTrue(B.Enabled);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TSerializerTests.ItemRoundtrip;
var
  A, B: TCustomItem;
  J: TJSONObject;
begin
  A := TCustomItem.Create;
  B := TCustomItem.Create;
  try
    A.Id := 1; A.ListId := 2; A.StreamItemId := 9; A.CustomGroupId := 4;
    A.DisplayName := 'Renamed'; A.ChannelNumber := 42;
    J := ItemToJson(A);
    try
      ItemFromJson(J, B);
    finally
      J.Free;
    end;
    Assert.AreEqual(9, B.StreamItemId);
    Assert.AreEqual(4, B.CustomGroupId);
    Assert.AreEqual('Renamed', B.DisplayName);
    Assert.AreEqual(42, B.ChannelNumber);
  finally
    A.Free;
    B.Free;
  end;
end;

procedure TSerializerTests.IntArrayFromJsonParses;
var
  J: TJSONObject;
  Arr: TArray<Integer>;
begin
  J := TJSONObject(TJSONObject.ParseJSONValue('{"ids":[3,5,8]}'));
  try
    Arr := IntArrayFromJson(J, 'ids');
    Assert.AreEqual<Integer>(3, Length(Arr));
    Assert.AreEqual(8, Arr[2]);
    // missing key -> empty array
    Assert.AreEqual<Integer>(0, Length(IntArrayFromJson(J, 'missing')));
  finally
    J.Free;
  end;
end;

// Regression: the favorite-star / rename send a PARTIAL group patch. The API
// loads the existing group then merges, and GroupFromJson must only override the
// keys actually present — never blank the others. (Bug: star wiped the name.)
procedure TSerializerTests.GroupPartialPatchKeepsName;
var
  G: TCustomGroup;
  J: TJSONObject;
begin
  G := TCustomGroup.Create;
  try
    G.Id := 10; G.Name := 'Sport'; G.ContentType := ctLive; G.IsFavorite := False;
    J := TJSONObject.Create;
    try
      J.AddPair('id', TJSONNumber.Create(10));
      J.AddPair('isFavorite', TJSONBool.Create(True)); // favorite star: only id + isFavorite
      GroupFromJson(J, G);
    finally
      J.Free;
    end;
    Assert.AreEqual('Sport', G.Name, 'name preserved by a partial favorite toggle');
    Assert.IsTrue(G.IsFavorite, 'favorite flag applied');
    Assert.AreEqual(ctLive, G.ContentType, 'content type preserved');
  finally
    G.Free;
  end;
end;

procedure TSerializerTests.GroupPartialRenameKeepsFavorite;
var
  G: TCustomGroup;
  J: TJSONObject;
begin
  G := TCustomGroup.Create;
  try
    G.Id := 10; G.Name := 'Sport'; G.IsFavorite := True;
    J := TJSONObject.Create;
    try
      J.AddPair('id', TJSONNumber.Create(10));
      J.AddPair('name', 'News'); // rename: only id + name
      GroupFromJson(J, G);
    finally
      J.Free;
    end;
    Assert.AreEqual('News', G.Name);
    Assert.IsTrue(G.IsFavorite, 'favorite preserved by a partial rename');
  finally
    G.Free;
  end;
end;

procedure TSerializerTests.SourcePartialPatchKeepsFields;
var
  S: TSourceConfig;
  J: TJSONObject;
begin
  S := TSourceConfig.Create;
  try
    S.Id := 7; S.Name := 'P'; S.Url := 'http://x'; S.Username := 'u'; S.Password := 'pw';
    J := TJSONObject.Create;
    try
      J.AddPair('id', TJSONNumber.Create(7));
      J.AddPair('enabled', TJSONBool.Create(False)); // partial: only id + enabled
      SourceFromJson(J, S);
    finally
      J.Free;
    end;
    Assert.AreEqual('P', S.Name, 'name preserved by a partial patch');
    Assert.AreEqual('http://x', S.Url, 'url preserved');
    Assert.AreEqual('u', S.Username, 'username preserved');
    Assert.IsFalse(S.Enabled, 'enabled applied');
  finally
    S.Free;
  end;
end;

procedure TSerializerTests.ListPartialPatchKeepsFields;
var
  L: TCustomList;
  J: TJSONObject;
begin
  L := TCustomList.Create;
  try
    L.Id := 3; L.Name := 'Box'; L.OutputUsername := 'bu'; L.OutputPassword := 'bp'; L.Enabled := True;
    J := TJSONObject.Create;
    try
      J.AddPair('id', TJSONNumber.Create(3));
      J.AddPair('enabled', TJSONBool.Create(False));
      ListFromJson(J, L);
    finally
      J.Free;
    end;
    Assert.AreEqual('Box', L.Name);
    Assert.AreEqual('bu', L.OutputUsername, 'output credentials preserved by a partial patch');
    Assert.AreEqual('bp', L.OutputPassword);
    Assert.IsFalse(L.Enabled);
  finally
    L.Free;
  end;
end;

procedure TSerializerTests.ItemPartialPatchKeepsFields;
var
  I: TCustomItem;
  J: TJSONObject;
begin
  I := TCustomItem.Create;
  try
    I.Id := 1; I.StreamItemId := 9; I.CustomGroupId := 4; I.ChannelNumber := 42; I.DisplayName := 'Old';
    J := TJSONObject.Create;
    try
      J.AddPair('id', TJSONNumber.Create(1));
      J.AddPair('displayName', 'New'); // partial: only id + displayName
      ItemFromJson(J, I);
    finally
      J.Free;
    end;
    Assert.AreEqual('New', I.DisplayName);
    Assert.AreEqual(9, I.StreamItemId, 'stream link preserved');
    Assert.AreEqual(4, I.CustomGroupId, 'group preserved (not reset to upstream)');
    Assert.AreEqual(42, I.ChannelNumber, 'channel number preserved (not reset to 0)');
  finally
    I.Free;
  end;
end;


initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);

end.
