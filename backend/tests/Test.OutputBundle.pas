unit Test.OutputBundle;

{ The bouquet zip download (IPTV.Output.Bundle): safe file names and the zip
  holding the playlist and the guide. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  [TestFixture]
  TOutputBundleTests = class
  public
    /// <summary>Unsafe characters collapse to one '_', edges are trimmed, long names
    /// are cut, and an empty result falls back to the default name.</summary>
    [Test] procedure BaseNameIsSafeAscii;
    /// <summary>The zip holds &lt;name&gt;.m3u and &lt;name&gt;.xml with the given UTF-8
    /// content, and the stream starts at position 0.</summary>
    [Test] procedure ZipHoldsPlaylistAndGuide;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Zip,
  // own units
  IPTV.Output.Bundle;

procedure TOutputBundleTests.BaseNameIsSafeAscii;
begin
  Assert.AreEqual('Living_room', BundleBaseName('Living room'));
  Assert.AreEqual('Kids_Sport', BundleBaseName('  Kids / Sport!! '));
  Assert.AreEqual('NL-TV_1.2', BundleBaseName('NL-TV 1.2'));
  Assert.AreEqual('Woonkamer', BundleBaseName('..Woonkamer..'));
  Assert.AreEqual('Caf', BundleBaseName('Caf' + #$00E9), 'non-ASCII is replaced, edges trimmed');
  Assert.AreEqual(cDefaultBundleBaseName, BundleBaseName(''), 'empty');
  Assert.AreEqual(cDefaultBundleBaseName, BundleBaseName(#$2605 + ' ' + #$2605), 'nothing usable');
  Assert.AreEqual(64, Length(BundleBaseName(StringOfChar('a', 100))), 'cut to 64');
end;

procedure TOutputBundleTests.ZipHoldsPlaylistAndGuide;
const
  cM3u = '#EXTM3U' + #10 + '#EXTINF:-1,Caf' + #$00E9 + ' TV' + #10 + 'http://example/1.ts' + #10;
  cXml = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
var
  lStream: TMemoryStream;
  lZip: TZipFile;
  lBytes: TBytes;
begin
  lStream := BuildBouquetZip(cM3u, cXml, 'Living_room');
  try
    Assert.AreEqual(Int64(0), lStream.Position, 'ready to send');
    lZip := TZipFile.Create;
    try
      lZip.Open(lStream, zmRead);
      Assert.AreEqual(2, lZip.FileCount);
      Assert.AreEqual('Living_room.m3u', lZip.FileNames[0]);
      Assert.AreEqual('Living_room.xml', lZip.FileNames[1]);
      lZip.Read('Living_room.m3u', lBytes);
      Assert.AreEqual(cM3u, TEncoding.UTF8.GetString(lBytes), 'playlist, UTF-8');
      lZip.Read('Living_room.xml', lBytes);
      Assert.AreEqual(cXml, TEncoding.UTF8.GetString(lBytes), 'guide');
      lZip.Close;
    finally
      FreeAndNil(lZip);
    end;
  finally
    FreeAndNil(lStream);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TOutputBundleTests);

end.
