program Utf8Probe;

{$APPTYPE CONSOLE}

{ Empirical probe: which FireDAC/SQLite write strategy stores correct UTF-8 for
  a non-CP1252 char (U+26BD '⚽')? Prints hex(stored bytes) + the round-tripped
  Delphi string codepoint for each strategy. Throwaway — not part of the suite. }

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Data.DB,
  // third-party
  FireDAC.Stan.Intf,
  FireDAC.Stan.Async,
  FireDAC.Comp.Client,
  FireDAC.Stan.Def,
  FireDAC.Stan.Param,
  FireDAC.DApt,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat;

const
  UNI = 'A'#$26BD'B'; // A⚽B

var
  Conn: TFDConnection;
  DbPath: string;

procedure Report(const ALabel: string);
var
  lQuery: TFDQuery;
  lHex: string;
  lName: string;
  lSqlLen: Integer;
  lCp: Integer;
begin
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := Conn;
    lQuery.Open('SELECT hex(name) AS h, name AS n, length(name) AS sqllen FROM t ORDER BY rowid DESC LIMIT 1');
    lHex := lQuery.FieldByName('h').AsString;
    lName := lQuery.FieldByName('n').AsString;
    lSqlLen := lQuery.FieldByName('sqllen').AsInteger;
    lCp := 0;
    if Length(lName) >= 2 then
      lCp := Ord(lName[2]);
    Writeln(Format('%-26s bytes=%-12s delphiLen=%d sqlLen=%d N[2]=U+%4.4X %s',
      [ALabel, lHex, Length(lName), lSqlLen, lCp,
       BoolToStr((lHex = '41E29ABD42') and (lCp = $26BD), True)]));
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure WriteAsString;
var
  lQuery: TFDQuery;
begin
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := Conn;
    lQuery.SQL.Text := 'INSERT INTO t(name) VALUES (:p)';
    lQuery.ParamByName('p').AsString := UNI;
    lQuery.ExecSQL;
  finally
    FreeAndNil(lQuery);
  end;
  Report('AsString');
end;

procedure WriteAsWideString;
var
  lQuery: TFDQuery;
begin
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := Conn;
    lQuery.SQL.Text := 'INSERT INTO t(name) VALUES (:p)';
    lQuery.Params[0].DataType := ftWideString;
    lQuery.Params[0].AsWideString := UNI;
    lQuery.ExecSQL;
  finally
    FreeAndNil(lQuery);
  end;
  Report('AsWideString(ftWide)');
end;

procedure WriteCastBytes;
var
  lQuery: TFDQuery;
  lStream: TBytesStream;
begin
  lStream := TBytesStream.Create(TEncoding.UTF8.GetBytes(UNI));
  lQuery := TFDQuery.Create(nil);
  try
    lQuery.Connection := Conn;
    lQuery.SQL.Text := 'INSERT INTO t(name) VALUES (CAST(:p AS TEXT))';
    lStream.Position := 0;
    lQuery.Params[0].LoadFromStream(lStream, ftBlob);
    lQuery.ExecSQL;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lStream);
  end;
  Report('CAST(:bytes AS TEXT)');
end;

procedure OpenConn(const AStringFormat: string; AMapRules, AUnicodeDriver: Boolean);
begin
  if TFile.Exists(DbPath) then
    TFile.Delete(DbPath);
  Conn := TFDConnection.Create(nil);
  Conn.DriverName := 'SQLite';
  Conn.Params.Database := DbPath;
  if AStringFormat <> '' then
    Conn.Params.Values['StringFormat'] := AStringFormat;
  if AUnicodeDriver then
    Conn.Params.Values['GUIDFormat'] := 'String'; // harmless; placeholder
  if AMapRules then
  begin
    Conn.FormatOptions.OwnMapRules := True;
    // Add(source, target) = Add + set SourceDataType/TargetDataType
    Conn.FormatOptions.MapRules.Add(dtAnsiString, dtWideString);
    Conn.FormatOptions.MapRules.Add(dtMemo, dtWideMemo);
  end;
  Conn.Connected := True;
  Conn.ExecSQL('CREATE TABLE t(name TEXT)');
end;

procedure Variant(const ALabel, ASF: string; AMap: Boolean);
begin
  Writeln;
  Writeln('=== ', ALabel, ' ===');
  OpenConn(ASF, AMap, False);
  try
    WriteAsString;
    WriteAsWideString;
    WriteCastBytes;
  finally
    FreeAndNil(Conn);
  end;
end;

begin
  try
    DbPath := TPath.Combine(TPath.GetTempPath, 'utf8probe.db');
    Writeln('target bytes for A=41 U+26BD=E29ABD B=42  -> 41E29ABD42');
    Writeln('PASS column = stored bytes correct AND read-back codepoint correct');

    Variant('StringFormat=Unicode + MapRules (current prod)', 'Unicode', True);
    Variant('StringFormat=Unicode, NO MapRules', 'Unicode', False);
    Variant('no StringFormat, NO MapRules (FireDAC default)', '', False);
    Variant('StringFormat=ANSI', 'ANSI', False);

    if TFile.Exists(DbPath) then
      TFile.Delete(DbPath);
  except
    on E: Exception do
      Writeln('ERROR ', E.ClassName, ': ', E.Message);
  end;
end.
