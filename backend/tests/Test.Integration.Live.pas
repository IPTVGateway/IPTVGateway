unit Test.Integration.Live;

{ Live integration tests against a REAL provider. These are OPT-IN: each test
  ignores itself unless credentials are present, so the default suite never
  touches the network and no secrets are needed.

  Provide credentials via either:
    - env var IPTV_TEST_CREDENTIALS = full path to a JSON file, or
    - a file 'test.credentials.json' in the working dir or next to the exe.
  See test.credentials.json (gitignored) for the shape. Leave a section's url
  empty to skip that section. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TLiveTests = class
  private
    FCreds: TObject; // TJSONObject or nil
    function Section(const AName: string): TObject; // TJSONObject or nil
    function SectionUrl(const AName: string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure XtreamReadsLiveStreams;
    // EPG / standalone-M3U live tests come later (user request: Xtream first).
  end;

implementation

uses
  Winapi.Windows, // silences H2443 (TDirectory inline expansion)
  System.SysUtils, System.IOUtils, System.JSON,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog,
  IPTV.Source.Intf, IPTV.Source.Xtream;

function FindCredsPath: string;
var
  Candidates: TArray<string>;
  C: string;
begin
  Result := GetEnvironmentVariable('IPTV_TEST_CREDENTIALS');
  if (Result <> '') and TFile.Exists(Result) then
    Exit;
  Candidates := [
    TPath.Combine(TDirectory.GetCurrentDirectory, 'test.credentials.json'),
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'test.credentials.json')
  ];
  for C in Candidates do
    if TFile.Exists(C) then
      Exit(C);
  Result := '';
end;

procedure TLiveTests.Setup;
var
  Path: string;
begin
  FCreds := nil;
  Path := FindCredsPath;
  if Path <> '' then
    FCreds := TJSONObject.ParseJSONValue(TFile.ReadAllText(Path));
end;

procedure TLiveTests.TearDown;
begin
  FCreds.Free;
end;

function TLiveTests.Section(const AName: string): TObject;
begin
  Result := nil;
  if (FCreds is TJSONObject) and (TJSONObject(FCreds).GetValue(AName) is TJSONObject) then
    Result := TJSONObject(FCreds).GetValue(AName);
end;

function TLiveTests.SectionUrl(const AName: string): string;
var
  Sec: TObject;
begin
  Sec := Section(AName);
  if Sec = nil then
    Exit('');
  Result := TJSONObject(Sec).GetValue<string>('url', '');
end;

procedure TLiveTests.XtreamReadsLiveStreams;
var
  Sec: TJSONObject;
  Src: TSourceConfig;
  Reader: ISourceReader;
  Snap: TSourceSnapshot;
begin
  if SectionUrl('xtream') = '' then
    Assert.Pass('no xtream credentials in test.credentials.json');
  Sec := TJSONObject(Section('xtream'));

  Src := TSourceConfig.Create;
  try
    Src.Kind := skXtream;
    Src.Url := Sec.GetValue<string>('url', '');
    Src.Username := Sec.GetValue<string>('username', '');
    Src.Password := Sec.GetValue<string>('password', '');
    // optional: mimic a specific box (e.g. the Formuler's UA) to get past panels
    // that drop unknown clients — set these in test.credentials.json to experiment.
    Src.UserAgent := Sec.GetValue<string>('userAgent', '');
    Src.Referer := Sec.GetValue<string>('referer', '');
    Src.ContentTypes := [ctLive];

    Reader := TXtreamReader.Create;
    Snap := Reader.Read(Src);
    try
      Assert.IsTrue(Snap.Streams.Count > 0, 'portal returned at least one live stream');
      Assert.IsTrue(Snap.Streams[0].UpstreamUrl.StartsWith('http'), 'a usable upstream URL was built');
    finally
      Snap.Free;
    end;
  finally
    Src.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLiveTests);

end.
