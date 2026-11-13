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
  System.SysUtils;

procedure KeepOneSourcePerChannel(AList: TEpgProgrammeList; ANowUtc: TDateTime);
type
  TScore = record
    Future, Total: Integer;
  end;
var
  Scores: TDictionary<string, TScore>;  // key: tvg-id + #1 + source id
  Best: TDictionary<string, Integer>;   // tvg-id -> chosen source id
  P: TEpgProgramme;
  Key: string;
  Sc, BestSc: TScore;
  Pair: TPair<string, TScore>;
  Tvg: string;
  Src, Sep, I, Cur: Integer;
begin
  if (AList = nil) or (AList.Count = 0) then
    Exit;
  Scores := TDictionary<string, TScore>.Create;
  Best := TDictionary<string, Integer>.Create;
  try
    for P in AList do
    begin
      Key := P.ChannelTvgId + #1 + P.SourceId.ToString;
      if not Scores.TryGetValue(Key, Sc) then
        Sc := Default(TScore);
      Inc(Sc.Total);
      if P.StopUtc > ANowUtc then
        Inc(Sc.Future);
      Scores.AddOrSetValue(Key, Sc);
    end;
    for Pair in Scores do
    begin
      Sep := Pair.Key.LastIndexOf(#1);
      Tvg := Pair.Key.Substring(0, Sep);
      Src := StrToIntDef(Pair.Key.Substring(Sep + 1), 0);
      if Best.TryGetValue(Tvg, Cur) then
      begin
        BestSc := Scores[Tvg + #1 + Cur.ToString];
        if (Pair.Value.Future < BestSc.Future) or
           ((Pair.Value.Future = BestSc.Future) and (Pair.Value.Total < BestSc.Total)) or
           ((Pair.Value.Future = BestSc.Future) and (Pair.Value.Total = BestSc.Total) and (Src > Cur)) then
          Continue;
      end;
      Best.AddOrSetValue(Tvg, Src);
    end;
    for I := AList.Count - 1 downto 0 do
      if Best.TryGetValue(AList[I].ChannelTvgId, Cur) and (AList[I].SourceId <> Cur) then
        AList.Delete(I);
  finally
    Best.Free;
    Scores.Free;
  end;
end;

end.
