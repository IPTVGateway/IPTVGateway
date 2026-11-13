unit IPTV.Source.Intf;

{ Reader abstractions. A source reader turns one TSourceConfig into a
  TSourceSnapshot (categories + streams), honouring the source's enabled
  content types. An EPG reader turns an XMLTV document into programmes. }

interface

uses
  IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg;

type
  ISourceReader = interface
    ['{7B2A9C10-1F3D-4E6A-9B2C-1A2B3C4D5E6F}']
    /// Read all enabled content types for the source into a fresh snapshot.
    function Read(const ASource: TSourceConfig): TSourceSnapshot;
  end;

  IEpgReader = interface
    ['{3C4D5E6F-7A8B-49C0-B1D2-E3F4A5B6C7D8}']
    /// Fetch + parse the XMLTV guide for a source. Only programmes whose channel
    /// is in AKeepTvgIds are returned (empty => keep all). Provider guides can be
    /// 100+ MB / hundreds of thousands of programmes, so this streams/scans the
    /// XML (no DOM) and filters to the channels we actually have. Caller owns it.
    function Read(const ASource: TSourceConfig; const AKeepTvgIds: TArray<string>): TEpgProgrammeList;
  end;

implementation

end.
