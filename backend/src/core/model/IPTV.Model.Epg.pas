unit IPTV.Model.Epg;

{ Electronic Program Guide. EPG is ingested from XMLTV (Xtream xmltv.php or the
  M3U url-tvg attribute) and re-served downstream as XMLTV via xmltv.php.

  Programmes are keyed by ChannelTvgId, which is matched against
  TStreamItem.TvgId to attach guide data to a channel. }

interface

uses
  System.Generics.Collections;

type
  TEpgProgramme = class
  private
    FId: Integer;
    FSourceId: Integer;
    FChannelTvgId: string;
    FStartUtc: TDateTime;
    FStopUtc: TDateTime;
    FTitle: string;
    FDescription: string;
    FCategory: string;
  public
    property Id: Integer read FId write FId;
    property SourceId: Integer read FSourceId write FSourceId;
    property ChannelTvgId: string read FChannelTvgId write FChannelTvgId;
    property StartUtc: TDateTime read FStartUtc write FStartUtc;
    property StopUtc: TDateTime read FStopUtc write FStopUtc;
    property Title: string read FTitle write FTitle;
    property Description: string read FDescription write FDescription;
    property Category: string read FCategory write FCategory;
  end;

  TEpgProgrammeList = class(TObjectList<TEpgProgramme>);

implementation

end.
