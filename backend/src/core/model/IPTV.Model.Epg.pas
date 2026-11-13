unit IPTV.Model.Epg;

{ Electronic Program Guide. EPG is ingested from XMLTV (Xtream xmltv.php or the
  M3U url-tvg attribute) and re-served downstream as XMLTV via xmltv.php.

  Programmes are keyed by ChannelTvgId, which is matched against
  TStreamItem.TvgId to attach guide data to a channel. }

interface

uses
  // RTL
  System.Generics.Collections;

type
  /// One guide programme of one channel (tvg-id) from one source.
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

  /// Owning list of guide programmes.
  TEpgProgrammeList = class(TObjectList<TEpgProgramme>);

  /// A <channel> of an XMLTV guide (id + first display-name). Kept for the extra
  /// (third-party) guides so list channels can be matched to them by id/name.
  TEpgChannelInfo = record
    Id: string;
    Name: string;
  end;

const
  /// Stored channel ids of an extra guide carry this prefix, so they can never
  /// collide with a provider's own tvg-ids in the epg table.
  EXTRA_EPG_PREFIX = 'extra:';

/// Several providers often deliver a guide for the SAME tvg-id; served together
/// every programme shows up 2-3 times (and slightly shifted copies overlap).
/// Keep, per channel, the programmes of ONE source: the one covering the most
/// programmes from ANowUtc on (ties: most programmes overall, then lowest
/// source id). Order of the remaining items is preserved.
procedure KeepOneSourcePerChannel(AList: TEpgProgrammeList; ANowUtc: TDateTime);

implementation

uses
  // RTL
  System.SysUtils;

const
  // KeepOneSourcePerChannel: separates tvg-id and source id in a score key
  // (a control char, so it can never be part of a tvg-id)
  cScoreKeySep = #1;

procedure KeepOneSourcePerChannel(AList: TEpgProgrammeList; ANowUtc: TDateTime);
type
  TScore = record
    Future, Total: Integer;
  end;
var
  lScores: TDictionary<string, TScore>;  // key: tvg-id + cScoreKeySep + source id
  lBest: TDictionary<string, Integer>;   // tvg-id -> chosen source id
  lProgramme: TEpgProgramme;
  lKey: string;
  lScore, lBestScore: TScore;
  lPair: TPair<string, TScore>;
  lTvg: string;
  lSrc, lSep, i, lCur: Integer;
begin
  if (AList = nil) or (AList.Count = 0) then
    Exit;
  lScores := nil;
  lBest := nil;
  try
    lScores := TDictionary<string, TScore>.Create;
    lBest := TDictionary<string, Integer>.Create;
    for lProgramme in AList do
    begin
      lKey := lProgramme.ChannelTvgId + cScoreKeySep + lProgramme.SourceId.ToString;
      if not lScores.TryGetValue(lKey, lScore) then
        lScore := Default(TScore);
      Inc(lScore.Total);
      if lProgramme.StopUtc > ANowUtc then
        Inc(lScore.Future);
      lScores.AddOrSetValue(lKey, lScore);
    end;
    for lPair in lScores do
    begin
      lSep := lPair.Key.LastIndexOf(cScoreKeySep);
      lTvg := lPair.Key.Substring(0, lSep);
      lSrc := StrToIntDef(lPair.Key.Substring(lSep + 1), 0);
      if lBest.TryGetValue(lTvg, lCur) then
      begin
        lBestScore := lScores[lTvg + cScoreKeySep + lCur.ToString];
        if (lPair.Value.Future < lBestScore.Future) or
           ((lPair.Value.Future = lBestScore.Future) and (lPair.Value.Total < lBestScore.Total)) or
           ((lPair.Value.Future = lBestScore.Future) and (lPair.Value.Total = lBestScore.Total) and
            (lSrc > lCur)) then
          Continue;
      end;
      lBest.AddOrSetValue(lTvg, lSrc);
    end;
    for i := AList.Count - 1 downto 0 do
      if lBest.TryGetValue(AList[i].ChannelTvgId, lCur) and (AList[i].SourceId <> lCur) then
        AList.Delete(i);
  finally
    FreeAndNil(lBest);
    FreeAndNil(lScores);
  end;
end;

end.
