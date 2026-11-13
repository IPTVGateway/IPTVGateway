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
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Opt-in live tests against a real provider (skipped without credentials).</summary>
  [TestFixture]
  TLiveTests = class
  private
    FCreds: TObject; // TJSONObject or nil
    /// <summary>Returns the named credentials section, or nil.</summary>
    function Section(const AName: string): TObject; // TJSONObject or nil
    /// <summary>Returns the url of the named credentials section ('' = skip).</summary>
    function SectionUrl(const AName: string): string;
  public
    /// <summary>Loads the credentials file, if any.</summary>
    [Setup] procedure Setup;
    /// <summary>Frees the loaded credentials.</summary>
    [TearDown] procedure TearDown;
    /// <summary>An Xtream portal returns live streams with usable upstream URLs.</summary>
    [Test] procedure XtreamReadsLiveStreams;
    // EPG / standalone-M3U live tests come later (user request: Xtream first).
  end;

implementation

uses
  // RTL
  Winapi.Windows, // silences H2443 (TDirectory inline expansion)
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Source.Intf,
  IPTV.Source.Xtream;

function FindCredsPath: string;
var
  lCandidates: TArray<string>;
  lCandidate: string;
begin
  Result := GetEnvironmentVariable('IPTV_TEST_CREDENTIALS');
  if (Result <> '') and TFile.Exists(Result) then
    Exit;
  lCandidates := [
    TPath.Combine(TDirectory.GetCurrentDirectory, 'test.credentials.json'),
    TPath.Combine(ExtractFilePath(ParamStr(0)), 'test.credentials.json')
  ];
  for lCandidate in lCandidates do
    if TFile.Exists(lCandidate) then
      Exit(lCandidate);
  Result := '';
end;

procedure TLiveTests.Setup;
var
  lPath: string;
begin
  FCreds := nil;
  lPath := FindCredsPath;
  if lPath <> '' then
    FCreds := TJSONObject.ParseJSONValue(TFile.ReadAllText(lPath));
end;

procedure TLiveTests.TearDown;
begin
  FreeAndNil(FCreds);
end;

function TLiveTests.Section(const AName: string): TObject;
begin
  Result := nil;
  if (FCreds is TJSONObject) and (TJSONObject(FCreds).GetValue(AName) is TJSONObject) then
    Result := TJSONObject(FCreds).GetValue(AName);
end;

function TLiveTests.SectionUrl(const AName: string): string;
var
  lSection: TObject;
begin
  lSection := Section(AName);
  if lSection = nil then
    Exit('');
  Result := TJSONObject(lSection).GetValue<string>('url', '');
end;

procedure TLiveTests.XtreamReadsLiveStreams;
var
  lSection: TJSONObject;
  lSource: TSourceConfig;
  lReader: ISourceReader;
  lSnapshot: TSourceSnapshot;
begin
  if SectionUrl('xtream') = '' then
    Assert.Pass('no xtream credentials in test.credentials.json');
  lSection := TJSONObject(Section('xtream'));

  lSource := TSourceConfig.Create;
  try
    lSource.Kind := skXtream;
    lSource.Url := lSection.GetValue<string>('url', '');
    lSource.Username := lSection.GetValue<string>('username', '');
    lSource.Password := lSection.GetValue<string>('password', '');
    // optional: mimic a specific box (e.g. the Formuler's UA) to get past panels
    // that drop unknown clients — set these in test.credentials.json to experiment.
    lSource.UserAgent := lSection.GetValue<string>('userAgent', '');
    lSource.Referer := lSection.GetValue<string>('referer', '');
    lSource.ContentTypes := [ctLive];

    lReader := TXtreamReader.Create;
    lSnapshot := lReader.Read(lSource);
    try
      Assert.IsTrue(lSnapshot.Streams.Count > 0, 'portal returned at least one live stream');
      Assert.IsTrue(lSnapshot.Streams[0].UpstreamUrl.StartsWith('http'), 'a usable upstream URL was built');
    finally
      FreeAndNil(lSnapshot);
    end;
  finally
    FreeAndNil(lSource);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLiveTests);

end.
