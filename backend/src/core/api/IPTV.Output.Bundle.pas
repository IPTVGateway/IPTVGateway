unit IPTV.Output.Bundle;

{ A bouquet as ONE download: its M3U playlist and its XMLTV guide together in a
  zip (GET /api/lists/:id/export.zip). The documents themselves come from
  IPTV.Output.Builder (the same content as export.m3u / export.xmltv); this unit
  only names and packs them. }

interface

uses
  // RTL
  System.Classes;

const
  /// File name used when a bouquet name has nothing usable left.
  cDefaultBundleBaseName = 'bouquet';
  cBundleM3uExt = '.m3u';
  cBundleXmltvExt = '.xml';
  cBundleZipExt = '.zip';

/// <summary>A safe, ASCII-only file base name for a bouquet: letters, digits, '-',
/// '_' and '.' are kept, every other run of characters becomes one '_', leading and
/// trailing '_'/'.' are dropped and the result is at most 64 characters.
/// '' -> cDefaultBundleBaseName.</summary>
function BundleBaseName(const AListName: string): string;

/// <summary>A zip holding AM3u as &lt;ABaseName&gt;.m3u and AXmltv as
/// &lt;ABaseName&gt;.xml (both UTF-8, no BOM), positioned at 0. Caller owns it.</summary>
function BuildBouquetZip(const AM3u, AXmltv, ABaseName: string): TMemoryStream;

implementation

uses
  // RTL
  System.SysUtils,
  System.Zip;

const
  cMaxBaseNameLen = 64;
  cNameSep = '_';
  cTrimChars: array[0..1] of Char = ('_', '.');

function IsSafeNameChar(AChar: Char): Boolean;
begin
  Result := CharInSet(AChar, ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.']);
end;

function BundleBaseName(const AListName: string): string;
var
  lBuilder: TStringBuilder;
  lLastWasSep: Boolean;
  lChar: Char;
begin
  lBuilder := TStringBuilder.Create;
  try
    lLastWasSep := False;
    for lChar in AListName do
      if IsSafeNameChar(lChar) then
      begin
        lBuilder.Append(lChar);
        lLastWasSep := False;
      end
      else if not lLastWasSep then
      begin
        lBuilder.Append(cNameSep);
        lLastWasSep := True;
      end;
    Result := lBuilder.ToString.Trim(cTrimChars);
  finally
    FreeAndNil(lBuilder);
  end;
  if Length(Result) > cMaxBaseNameLen then
    Result := Copy(Result, 1, cMaxBaseNameLen).TrimRight(cTrimChars);
  if Result = '' then
    Result := cDefaultBundleBaseName;
end;

function BuildBouquetZip(const AM3u, AXmltv, ABaseName: string): TMemoryStream;
var
  lZip: TZipFile;
begin
  Result := TMemoryStream.Create;
  try
    lZip := TZipFile.Create;
    try
      lZip.Open(Result, zmWrite);
      lZip.Add(TEncoding.UTF8.GetBytes(AM3u), ABaseName + cBundleM3uExt);
      lZip.Add(TEncoding.UTF8.GetBytes(AXmltv), ABaseName + cBundleXmltvExt);
      lZip.Close;
    finally
      FreeAndNil(lZip);
    end;
    Result.Position := 0;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

end.
