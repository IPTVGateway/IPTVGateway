unit Test.Ingest;

{ Ingest-side robustness: lenient UTF-8 decoding of provider bodies, extra-EPG
  slots that follow their URL, and the daily scheduler's persisted last run. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for the decode / extra-EPG / scheduler fixes.</summary>
  [TestFixture]
  TIngestTests = class
  private
    FDbPath: string;
  public
    /// <summary>Picks a unique temp database path for the test.</summary>
    [Setup] procedure Setup;
    /// <summary>Deletes the temp database and its WAL/SHM side files.</summary>
    [TearDown] procedure TearDown;

    /// <summary>A CESU-8 surrogate (ED A0..BF xx) becomes U+FFFD instead of raising.</summary>
    [Test] procedure DecodeBytes_SurrogateDoesNotRaise;
    /// <summary>Overlong forms (C0 80, E0 80..9F, F0 80..8F) become U+FFFD.</summary>
    [Test] procedure DecodeBytes_OverlongDoesNotRaise;
    /// <summary>Lead bytes F5..FF (and F4 above U+10FFFF) become U+FFFD.</summary>
    [Test] procedure DecodeBytes_LeadAboveF4DoesNotRaise;
    /// <summary>Valid multi-byte UTF-8 (2, 3 and 4 bytes) still decodes exactly.</summary>
    [Test] procedure DecodeBytes_ValidUtf8Unchanged;
    /// <summary>A UTF-8 BOM body with a bad sequence decodes leniently, BOM dropped.</summary>
    [Test] procedure DecodeBytes_BomWithBadSequence;
    /// <summary>A removed URL's slot goes at once; a changed slot keeps its guide until its download.</summary>
    [Test] procedure ExtraEpgSlotFollowsItsUrl;
    /// <summary>The first run after the upgrade (no URL recorded) keeps every extra guide.</summary>
    [Test] procedure ExtraEpgFirstRunKeepsGuides;
    /// <summary>A changed slot: a failed download empties it, a usable one replaces it.</summary>
    [Test] procedure ExtraEpgChangedSlotSettledByDownload;
    /// <summary>The last scheduled run date round-trips through the app state.</summary>
    [Test] procedure SchedulerLastRunPersists;
    /// <summary>A scheduler that already ran today (persisted) doesn't fire again after a restart.</summary>
    [Test] procedure SchedulerSkipsRunDoneBeforeRestart;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  System.SyncObjs,
  // own units
  IPTV.Core.Utils,
  IPTV.Model.Epg,
  IPTV.Storage.Intf,
  IPTV.Storage.SQLite,
  IPTV.Source.Http,
  IPTV.Ingest.Service,
  IPTV.Scheduler;

const
  cReplacementChar = #$FFFD;
  cOwnsObjects = True;
  cFireWaitMs = 3000;   // a due scheduler fires right after its thread starts
  cNoFireWaitMs = 1500;
  cMinutesBack = 1;     // the configured time lies this far in the past: inside the window
  // enough valid multi-byte text around one bad sequence that the body still counts
  // as UTF-8 (a tiny body with a bad byte is decoded as a legacy code page instead)
  cValidTailChars = 400;

function NewStore(const APath: string): IStore;
begin
  Result := TSQLiteStore.Create(APath);
  Result.Init;
end;

function Bytes(const AValues: array of Byte): TBytes;
var
  i: Integer;
begin
  SetLength(Result, Length(AValues));
  for i := 0 to High(AValues) do
    Result[i] := AValues[i];
end;

// 'A' + ABad + 'B' + cValidTailChars e-acutes (C3 A9)
function MostlyUtf8(const ABad: array of Byte): TBytes;
var
  i, lPos: Integer;
begin
  SetLength(Result, Length(ABad) + 2 + 2 * cValidTailChars);
  Result[0] := Ord('A');
  for i := 0 to High(ABad) do
    Result[1 + i] := ABad[i];
  lPos := 1 + Length(ABad);
  Result[lPos] := Ord('B');
  Inc(lPos);
  for i := 1 to cValidTailChars do
  begin
    Result[lPos] := $C3;
    Result[lPos + 1] := $A9;
    Inc(lPos, 2);
  end;
end;

// what MostlyUtf8 decodes to when ABad becomes AReplaced replacement chars
function Expected(AReplaced: Integer): string;
begin
  Result := 'A' + StringOfChar(cReplacementChar, AReplaced) + 'B' + StringOfChar(#$00E9, cValidTailChars);
end;

function GuideOf(const ATvgId: string): TEpgProgrammeList;
var
  lProg: TEpgProgramme;
begin
  Result := TEpgProgrammeList.Create(cOwnsObjects);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := ATvgId;
  lProg.Title := 'Show';
  lProg.StartUtc := IncHour(NowUtc, 1);
  lProg.StopUtc := IncHour(NowUtc, 2);
  Result.Add(lProg);
end;

function CountEpg(const AStore: IStore; const ATvgId: string): Integer;
var
  lList: TEpgProgrammeList;
begin
  lList := AStore.LoadEpgForTvgIds([ATvgId]);
  try
    Result := lList.Count;
  finally
    FreeAndNil(lList);
  end;
end;

procedure StoreGuide(const AStore: IStore; ASlot: Integer; const ATvgId: string);
var
  lProgs: TEpgProgrammeList;
begin
  lProgs := GuideOf(ATvgId);
  try
    AStore.ReplaceExtraEpg(ASlot, [], lProgs);
  finally
    FreeAndNil(lProgs);
  end;
end;

{ TIngestTests }

procedure TIngestTests.Setup;
begin
  FDbPath := TPath.Combine(TPath.GetTempPath, 'iptvingest_' + TGUID.NewGuid.ToString + '.sqlite');
end;

procedure TIngestTests.TearDown;

  procedure Del(const APath: string);
  begin
    if TFile.Exists(APath) then
      TFile.Delete(APath);
  end;

begin
  Del(FDbPath);
  Del(FDbPath + '-wal');
  Del(FDbPath + '-shm');
end;

procedure TIngestTests.DecodeBytes_SurrogateDoesNotRaise;
begin
  // ED A0 80 = a UTF-16 high surrogate written as CESU-8: three invalid bytes
  Assert.AreEqual(Expected(3), DecodeBytes(MostlyUtf8([$ED, $A0, $80])));
  // ED 9F BF (U+D7FF) is the last valid ED sequence
  Assert.AreEqual(#$D7FF, DecodeBytes(Bytes([$ED, $9F, $BF])));
  // a tiny body: decoded as a legacy code page, but never raises
  Assert.AreNotEqual('', DecodeBytes(Bytes([$41, $ED, $B0, $80])));
end;

procedure TIngestTests.DecodeBytes_OverlongDoesNotRaise;
begin
  Assert.AreEqual(Expected(2), DecodeBytes(MostlyUtf8([$C0, $80])), 'C0 80');
  Assert.AreEqual(Expected(3), DecodeBytes(MostlyUtf8([$E0, $9F, $BF])), 'E0 80..9F');
  Assert.AreEqual(Expected(4), DecodeBytes(MostlyUtf8([$F0, $8F, $BF, $BF])), 'F0 80..8F');
  Assert.AreNotEqual('', DecodeBytes(Bytes([$C1, $BF])), 'tiny body never raises');
end;

procedure TIngestTests.DecodeBytes_LeadAboveF4DoesNotRaise;
begin
  Assert.AreEqual(Expected(4), DecodeBytes(MostlyUtf8([$F5, $80, $80, $80])), 'F5');
  Assert.AreEqual(Expected(4), DecodeBytes(MostlyUtf8([$F7, $BF, $BF, $BF])), 'F7');
  // F4 90 80 80 = U+110000, beyond Unicode
  Assert.AreEqual(Expected(4), DecodeBytes(MostlyUtf8([$F4, $90, $80, $80])), 'F4 above U+10FFFF');
  Assert.AreNotEqual('', DecodeBytes(Bytes([$F6, $80, $80, $80])), 'tiny body never raises');
end;

procedure TIngestTests.DecodeBytes_ValidUtf8Unchanged;
begin
  // e-acute (2), euro sign (3), soccer ball (3), U+1F600 (4 bytes, a surrogate pair)
  Assert.AreEqual(#$00E9 + #$20AC + #$26BD + #$D83D#$DE00,
    DecodeBytes(Bytes([$C3, $A9, $E2, $82, $AC, $E2, $9A, $BD, $F0, $9F, $98, $80])));
  // F4 8F BF BF = U+10FFFF, the highest valid code point
  Assert.AreEqual(#$DBFF#$DFFF, DecodeBytes(Bytes([$F4, $8F, $BF, $BF])));
end;

procedure TIngestTests.DecodeBytes_BomWithBadSequence;
begin
  Assert.AreEqual('hi', DecodeBytes(Bytes([$EF, $BB, $BF, $68, $69])), 'plain BOM body');
  Assert.AreEqual('h' + StringOfChar(cReplacementChar, 3) + 'i',
    DecodeBytes(Bytes([$EF, $BB, $BF, $68, $ED, $B0, $80, $69])), 'BOM body with a surrogate');
end;

const
  cUrlA = 'http://guide-a/epg.xml';
  cUrlB = 'http://guide-b/epg.xml';
  cChanA = 'extra:a';
  cChanB = 'extra:b';

procedure TIngestTests.ExtraEpgSlotFollowsItsUrl;
var
  lStore: IStore;
begin
  lStore := NewStore(FDbPath);
  ResetChangedExtraEpgSlots(lStore, [cUrlA, cUrlB]);
  StoreGuide(lStore, -1, cChanA);
  StoreGuide(lStore, -2, cChanB);

  // same URLs: both slots keep their guide
  ResetChangedExtraEpgSlots(lStore, [cUrlA, cUrlB]);
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA), 'unchanged slot 1 kept');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanB), 'unchanged slot 2 kept');

  // A removed: B moves to slot 1 - slot 2 goes away at once, slot 1 waits for B's download
  ResetChangedExtraEpgSlots(lStore, [cUrlB]);
  Assert.AreEqual<Integer>(0, CountEpg(lStore, cChanB), 'removed slot 2 dropped');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA), 'changed slot 1 kept until its download');
end;

procedure TIngestTests.ExtraEpgFirstRunKeepsGuides;
var
  lStore: IStore;
begin
  lStore := NewStore(FDbPath);
  // guides stored by a version that didn't record the slot URLs yet
  StoreGuide(lStore, -1, cChanA);
  StoreGuide(lStore, -2, cChanB);
  ResetChangedExtraEpgSlots(lStore, [cUrlA, cUrlB]);
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA), 'slot 1 kept on the first run');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanB), 'slot 2 kept on the first run');
  // the URLs are recorded now: an empty download of the same URL keeps the guide
  Assert.IsTrue(ApplyExtraEpgDownload(lStore, 1, cUrlA, [], nil) = eoKept, 'same URL: kept');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA));
end;

procedure TIngestTests.ExtraEpgChangedSlotSettledByDownload;
var
  lStore: IStore;
  lEmpty, lProgs: TEpgProgrammeList;
begin
  lStore := NewStore(FDbPath);
  ResetChangedExtraEpgSlots(lStore, [cUrlA]);
  StoreGuide(lStore, -1, cChanA);
  ResetChangedExtraEpgSlots(lStore, [cUrlB]); // slot 1 now B, still holds A's guide

  // B's download brought nothing usable: A's guide must not stay under B
  lEmpty := TEpgProgrammeList.Create(cOwnsObjects);
  try
    Assert.IsTrue(ApplyExtraEpgDownload(lStore, 1, cUrlB, [], lEmpty) = eoEmptied, 'emptied');
  finally
    FreeAndNil(lEmpty);
  end;
  Assert.AreEqual<Integer>(0, CountEpg(lStore, cChanA), 'the previous URL''s guide is gone');
  Assert.IsTrue(ApplyExtraEpgDownload(lStore, 1, cUrlB, [], nil) = eoKept, 'B recorded: the next failure keeps');

  // back to A: a usable download replaces the slot right away
  ResetChangedExtraEpgSlots(lStore, [cUrlA]);
  lProgs := GuideOf(cChanA);
  try
    Assert.IsTrue(ApplyExtraEpgDownload(lStore, 1, cUrlA, [], lProgs) = eoStored, 'stored');
  finally
    FreeAndNil(lProgs);
  end;
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA), 'new guide stored');
  Assert.IsTrue(ApplyExtraEpgDownload(lStore, 1, cUrlA, [], nil) = eoKept, 'A recorded: a failure keeps it');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, cChanA));
end;

procedure TIngestTests.SchedulerLastRunPersists;
var
  lStore: IStore;
  lDay: TDate;
begin
  lStore := NewStore(FDbPath);
  Assert.AreEqual<TDate>(0, StoreLastRunLoader(lStore)(), 'never ran');
  lDay := EncodeDate(2026, 11, 14);
  StoreLastRunSaver(lStore)(lDay);
  Assert.AreEqual<TDate>(lDay, StoreLastRunLoader(lStore)());
  lStore := nil;
  lStore := NewStore(FDbPath); // a restart
  Assert.AreEqual<TDate>(lDay, StoreLastRunLoader(lStore)(), 'survives a restart');
end;

procedure TIngestTests.SchedulerSkipsRunDoneBeforeRestart;
var
  lTarget: TDateTime;
  lHour, lMinute, lSec, lMSec: Word;
  lFired: TEvent;
  lSaved: TDate;
  lScheduler: TDailyScheduler;
begin
  lTarget := IncMinute(Now, -cMinutesBack);
  if DateOf(lTarget) <> Date then
  begin
    Assert.Pass('just after midnight: the window check is not testable now');
    Exit;
  end;
  DecodeTime(lTarget, lHour, lMinute, lSec, lMSec);
  lFired := TEvent.Create(nil, True, False, '');
  try
    // control: inside the window and never ran -> fires and saves today
    lSaved := 0;
    lScheduler := TDailyScheduler.Create(lHour, lMinute,
      procedure
      begin
        lFired.SetEvent;
      end,
      function: TDate
      begin
        Result := 0;
      end,
      procedure(ADate: TDate)
      begin
        lSaved := ADate;
      end);
    try
      Assert.IsTrue(lFired.WaitFor(cFireWaitMs) = wrSignaled, 'due run fires');
    finally
      lScheduler.Terminate;
      FreeAndNil(lScheduler);
    end;
    Assert.AreEqual<TDate>(Date, lSaved, 'the run date is saved');

    // the restart: the persisted date says today already ran -> no second run
    lFired.ResetEvent;
    lScheduler := TDailyScheduler.Create(lHour, lMinute,
      procedure
      begin
        lFired.SetEvent;
      end,
      function: TDate
      begin
        Result := Date;
      end,
      nil);
    try
      Assert.IsTrue(lFired.WaitFor(cNoFireWaitMs) = wrTimeout, 'no second run after a restart');
    finally
      lScheduler.Terminate;
      FreeAndNil(lScheduler);
    end;
  finally
    FreeAndNil(lFired);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TIngestTests);

end.
