program Utf8Probe;

{$APPTYPE CONSOLE}

{ Empirical probe: which FireDAC/SQLite write strategy stores correct UTF-8 for
  a non-CP1252 char (U+26BD '⚽')? Prints hex(stored bytes) + the round-tripped
  Delphi string codepoint for each strategy. Throwaway — not part of the suite. }

uses
  System.SysUtils, System.Classes, System.IOUtils,
  FireDAC.Stan.Intf, FireDAC.Stan.Async, FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Param,
  FireDAC.DApt, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat,
  Data.DB;

const
  UNI = 'A'#$26BD'B'; // A⚽B

var
  Conn: TFDConnection;
  DbPath: string;

procedure Report(const ALabel: string);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.Open('SELECT hex(name) AS h, name AS n, length(name) AS sqllen FROM t ORDER BY rowid DESC LIMIT 1');
    var H := Q.FieldByName('h').AsString;
    var N := Q.FieldByName('n').AsString;
    var SqlLen := Q.FieldByName('sqllen').AsInteger;
    var Cp := 0;
    if Length(N) >= 2 then Cp := Ord(N[2]);
    Writeln(Format('%-26s bytes=%-12s delphiLen=%d sqlLen=%d N[2]=U+%4.4X %s',
      [ALabel, H, Length(N), SqlLen, Cp,
       BoolToStr((H = '41E29ABD42') and (Cp = $26BD), True)]));
  finally
    Q.Free;
  end;
end;

procedure WriteAsString;
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := 'INSERT INTO t(name) VALUES (:p)';
    Q.ParamByName('p').AsString := UNI;
    Q.ExecSQL;
  finally Q.Free; end;
  Report('AsString');
end;

procedure WriteAsWideString;
var Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := 'INSERT INTO t(name) VALUES (:p)';
    Q.Params[0].DataType := ftWideString;
    Q.Params[0].AsWideString := UNI;
    Q.ExecSQL;
  finally Q.Free; end;
  Report('AsWideString(ftWide)');
end;

procedure WriteCastBytes;
var Q: TFDQuery; MS: TBytesStream;
begin
  MS := TBytesStream.Create(TEncoding.UTF8.GetBytes(UNI));
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := Conn;
    Q.SQL.Text := 'INSERT INTO t(name) VALUES (CAST(:p AS TEXT))';
    MS.Position := 0;
    Q.Params[0].LoadFromStream(MS, ftBlob);
    Q.ExecSQL;
  finally Q.Free; MS.Free; end;
  Report('CAST(:bytes AS TEXT)');
end;

procedure OpenConn(AStringFormat: string; AMapRules, AUnicodeDriver: Boolean);
begin
  if TFile.Exists(DbPath) then TFile.Delete(DbPath);
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
    with Conn.FormatOptions.MapRules.Add do
    begin SourceDataType := dtAnsiString; TargetDataType := dtWideString; end;
    with Conn.FormatOptions.MapRules.Add do
    begin SourceDataType := dtMemo; TargetDataType := dtWideMemo; end;
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
    Conn.Free;
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

    if TFile.Exists(DbPath) then TFile.Delete(DbPath);
  except
    on E: Exception do
      Writeln('ERROR ', E.ClassName, ': ', E.Message);
  end;
end.
