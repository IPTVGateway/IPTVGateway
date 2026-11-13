unit IPTV.Source.Factory;

{ Resolves the right reader for a source kind. Keeps the ingest service free of
  concrete reader dependencies. }

interface

uses
  IPTV.Model.Types, IPTV.Source.Intf;

function CreateSourceReader(AKind: TSourceKind): ISourceReader;
function CreateEpgReader: IEpgReader;

implementation

uses
  IPTV.Source.M3U, IPTV.Source.Xtream, IPTV.Source.Stalker, IPTV.Source.Epg;

function CreateSourceReader(AKind: TSourceKind): ISourceReader;
begin
  case AKind of
    skXtream: Result := TXtreamReader.Create;
    skStalker: Result := TStalkerReader.Create;
  else
    Result := TM3UReader.Create;
  end;
end;

function CreateEpgReader: IEpgReader;
begin
  Result := TXmltvEpgReader.Create;
end;

end.
