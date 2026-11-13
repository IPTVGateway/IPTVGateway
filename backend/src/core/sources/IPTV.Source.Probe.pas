unit IPTV.Source.Probe;

(* Stream quality probe: pull a few seconds of a live channel and report what is
  really inside — video codec/profile, resolution, frame rate, interlacing, bit
  depth, audio tracks, media bitrate, and whether the server delivers at least
  real-time. Backs "measure this channel in all qualities" in the admin UI, so
  the operator can see that e.g. "4K+" is an upscaled 1080 or that "RAW" is the
  untouched 1080i broadcast.

  Pure Delphi, no ffmpeg: TTsAnalyzer parses MPEG-TS (PAT/PMT, PES timestamps,
  the H.264 / HEVC SPS and the MPEG-2 sequence header). HLS (.m3u8) is handled
  by reading the playlist (highest-bandwidth variant) and feeding its newest
  segments through the same analyzer; fMP4 HLS falls back to the playlist's
  CODECS/RESOLUTION attributes.

  Probes are serialised process-wide (GProbeLock): providers usually allow only
  1-2 concurrent connections per account, so never measure in parallel.
  The probe only READS from the provider; nothing is relayed or stored. *)

interface

uses
  System.SysUtils, System.Classes;

type
  TProbeAudio = record
    Codec: string;     // 'AAC', 'AC-3', 'E-AC-3', 'MP2', ...
    Language: string;  // ISO 639 code from the PMT ('' if none)
  end;

  TProbeResult = record
    Ok: Boolean;
    Error: string;          // why the probe failed, or a warning ('stalled')
    Container: string;      // 'mpegts' | 'hls' | 'hls-fmp4' | the content type
    VideoCodec: string;     // 'H.264' | 'HEVC' | 'MPEG-2' | 'MPEG-1' | ''
    Profile: string;        // e.g. 'High 4.0', 'Main 10 5.1'
    Width, Height: Integer;
    Fps: Double;            // frames per second (from the PES timestamps)
    Interlaced: Boolean;
    BitDepth: Integer;      // 8 / 10 (0 = unknown)
    Audio: TArray<TProbeAudio>;
    BitrateKbps: Integer;   // media bitrate: TS bytes over the timestamp span
    MediaSeconds: Double;   // seconds of media received
    WallSeconds: Double;    // time spent receiving (first byte -> stop)
    FirstByteMs: Integer;   // request -> first body byte (incl. redirects)
    Redirects: Integer;
    Bytes: Int64;
    /// MediaSeconds / WallSeconds: < 1 means the server can't keep up (buffering);
    /// > 1 is normal at the start (providers burst-fill the player's buffer).
    function Realtime: Double;
  end;

  /// Incremental MPEG-TS parser. Feed raw bytes (any chunking), then Finish.
  TTsAnalyzer = class
  private
    FCarry: TBytes;            // partial packet between Feed calls
    FSynced: Boolean;
    FPmtPid, FVideoPid: Integer;
    FPmtDone: Boolean;
    FVideoType: Integer;
    FAudio: TArray<TProbeAudio>;
    FVes: TBytes;              // collected video elementary stream (for the SPS)
    FVesLen: Integer;
    FPtsCount: Integer;
    FPtsFirst, FPtsMin, FPtsMax: Int64;
    FBytesTotal: Int64;
    FBytesAtMin, FBytesAtMax: Int64;
    procedure Packet(const P: PByte);
    procedure ParsePat(const P: PByte; ALen: Integer);
    procedure ParsePmt(const P: PByte; ALen: Integer);
    procedure VideoPayload(const P: PByte; ALen: Integer; AStart: Boolean);
    procedure AppendVes(const P: PByte; ALen: Integer);
  public
    procedure Feed(const ABuf; ACount: Integer);
    /// Drop any partial packet (call between HLS segments).
    procedure ResetSync;
    /// Fill the media fields of R from what was seen.
    procedure Finish(var R: TProbeResult);
    property BytesTotal: Int64 read FBytesTotal;
  end;

/// Probe a stream URL for at most AMaxSeconds of receiving (clamped 3..20).
/// Never raises; failures come back as Ok=False + Error.
/// AUserAgent / AReferer: the source's own settings ('' = VLC default UA).
function ProbeStream(const AUrl: string; AMaxSeconds: Integer = 8;
  const AUserAgent: string = ''; const AReferer: string = ''): TProbeResult;

// exposed for tests
function ParseH264Sps(const ANal: TBytes; var R: TProbeResult): Boolean;
function ParseHevcSps(const ANal: TBytes; var R: TProbeResult): Boolean;

implementation

uses
  System.SyncObjs, System.Diagnostics, System.Math, System.StrUtils,
  System.Generics.Collections,
  IdHTTP, IdSSLOpenSSL, IdURI;

const
  ProbeUA = 'VLC/3.0.21 LibVLC/3.0.21'; // default when the source sets no UA
  MaxVes = 1024 * 1024;        // video ES kept for SPS hunting
  MaxProbeBytes = 64 * 1024 * 1024;
  MaxPlaylistBytes = 1024 * 1024;

var
  GProbeLock: TCriticalSection;

function TProbeResult.Realtime: Double;
begin
  if WallSeconds > 0 then
    Result := MediaSeconds / WallSeconds
  else
    Result := 0;
end;

{ ── bit reader (RBSP, emulation-prevention already removed) ─────────────── }

type
  TBitReader = record
    Data: TBytes;
    Pos: Integer; // bit position
    function Bits(N: Integer): Cardinal;
    function Bit: Boolean;
    function UE: Cardinal;
    function SE: Integer;
    procedure Skip(N: Integer);
    function Eof: Boolean;
  end;

function TBitReader.Bits(N: Integer): Cardinal;
var
  I, B: Integer;
begin
  Result := 0;
  for I := 1 to N do
  begin
    if (Pos shr 3) >= Length(Data) then
      raise EConvertError.Create('SPS truncated');
    B := (Data[Pos shr 3] shr (7 - (Pos and 7))) and 1;
    Result := (Result shl 1) or Cardinal(B);
    Inc(Pos);
  end;
end;

function TBitReader.Bit: Boolean;
begin
  Result := Bits(1) = 1;
end;

function TBitReader.UE: Cardinal;
var
  Zeros: Integer;
begin
  Zeros := 0;
  while not Bit do
  begin
    Inc(Zeros);
    if Zeros > 31 then
      raise EConvertError.Create('bad exp-golomb');
  end;
  if Zeros = 0 then
    Exit(0);
  Result := (Cardinal(1) shl Zeros) - 1 + Bits(Zeros);
end;

function TBitReader.SE: Integer;
var
  K: Cardinal;
begin
  K := UE;
  if Odd(K) then
    Result := Integer((K + 1) div 2)
  else
    Result := -Integer(K div 2);
end;

procedure TBitReader.Skip(N: Integer);
begin
  Inc(Pos, N);
end;

function TBitReader.Eof: Boolean;
begin
  Result := (Pos shr 3) >= Length(Data);
end;

// strip the 0x03 emulation-prevention bytes (00 00 03 -> 00 00)
function Unescape(const P: PByte; ALen: Integer): TBytes;
var
  I, N, Zeros: Integer;
  B: Byte;
begin
  SetLength(Result, ALen);
  N := 0;
  Zeros := 0;
  for I := 0 to ALen - 1 do
  begin
    B := P[I];
    if (Zeros >= 2) and (B = 3) then
    begin
      Zeros := 0;
      Continue;
    end;
    if B = 0 then
      Inc(Zeros)
    else
      Zeros := 0;
    Result[N] := B;
    Inc(N);
  end;
  SetLength(Result, N);
end;

{ ── SPS parsers ─────────────────────────────────────────────────────────── }

function ParseH264Sps(const ANal: TBytes; var R: TProbeResult): Boolean;
var
  Br: TBitReader;
  ProfileIdc, LevelIdc, Chroma, PocType, I, J, Cnt, SizeOfList: Integer;
  LastScale, NextScale: Integer;
  WMbs, HMap: Cardinal;
  FrameMbsOnly: Boolean;
  CL, CR, CT, CB, CropX, CropY: Integer;
  PName: string;
begin
  // ANal = full NAL incl. its 1-byte header
  Br.Data := ANal;
  Br.Pos := 8;
  try
    ProfileIdc := Br.Bits(8);
    Br.Skip(8); // constraint flags
    LevelIdc := Br.Bits(8);
    Br.UE; // sps id
    Chroma := 1;
    R.BitDepth := 8;
    if ProfileIdc in [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135] then
    begin
      Chroma := Br.UE;
      if Chroma = 3 then
        Br.Skip(1); // separate_colour_plane
      R.BitDepth := Integer(Br.UE) + 8;
      Br.UE; // bit_depth_chroma
      Br.Skip(1); // qpprime_y_zero_transform_bypass
      if Br.Bit then // seq_scaling_matrix_present
      begin
        Cnt := IfThen(Chroma <> 3, 8, 12);
        for I := 0 to Cnt - 1 do
          if Br.Bit then
          begin
            SizeOfList := IfThen(I < 6, 16, 64);
            LastScale := 8;
            NextScale := 8;
            for J := 0 to SizeOfList - 1 do
            begin
              if NextScale <> 0 then
                NextScale := (LastScale + Br.SE + 256) mod 256;
              if NextScale <> 0 then
                LastScale := NextScale;
            end;
          end;
      end;
    end;
    Br.UE; // log2_max_frame_num_minus4
    PocType := Br.UE;
    if PocType = 0 then
      Br.UE
    else if PocType = 1 then
    begin
      Br.Skip(1);
      Br.SE;
      Br.SE;
      Cnt := Br.UE;
      for I := 1 to Cnt do
        Br.SE;
    end;
    Br.UE; // max_num_ref_frames
    Br.Skip(1); // gaps_in_frame_num_allowed
    WMbs := Br.UE;
    HMap := Br.UE;
    FrameMbsOnly := Br.Bit;
    if not FrameMbsOnly then
      Br.Skip(1); // mb_adaptive_frame_field
    Br.Skip(1); // direct_8x8_inference
    CL := 0; CR := 0; CT := 0; CB := 0;
    if Br.Bit then
    begin
      CL := Br.UE; CR := Br.UE; CT := Br.UE; CB := Br.UE;
    end;
    case Chroma of
      0: begin CropX := 1; CropY := 2 - Ord(FrameMbsOnly); end;
      1: begin CropX := 2; CropY := 2 * (2 - Ord(FrameMbsOnly)); end;
      2: begin CropX := 2; CropY := 2 - Ord(FrameMbsOnly); end;
    else
      CropX := 1; CropY := 2 - Ord(FrameMbsOnly);
    end;
    R.Width := Integer(WMbs + 1) * 16 - (CL + CR) * CropX;
    R.Height := (2 - Ord(FrameMbsOnly)) * Integer(HMap + 1) * 16 - (CT + CB) * CropY;
    R.Interlaced := not FrameMbsOnly;
    case ProfileIdc of
      66: PName := 'Baseline';
      77: PName := 'Main';
      88: PName := 'Extended';
      100: PName := 'High';
      110: PName := 'High 10';
      122: PName := 'High 4:2:2';
      244: PName := 'High 4:4:4';
    else
      PName := 'Profile ' + IntToStr(ProfileIdc);
    end;
    R.Profile := Format('%s %d.%d', [PName, LevelIdc div 10, LevelIdc mod 10]);
    R.VideoCodec := 'H.264';
    Result := (R.Width > 0) and (R.Height > 0);
  except
    on EConvertError do
      Result := False;
  end;
end;

function ParseHevcSps(const ANal: TBytes; var R: TProbeResult): Boolean;
var
  Br: TBitReader;
  MaxSub, I, ProfileIdc, LevelIdc, Chroma: Integer;
  ProgressiveSrc, InterlacedSrc: Boolean;
  SubProfile, SubLevel: array[0..7] of Boolean;
  W, H: Cardinal;
  CL, CR, CT, CB, SubW, SubH: Integer;
  PName: string;
begin
  Br.Data := ANal;
  Br.Pos := 16; // 2-byte NAL header
  try
    Br.Skip(4); // vps id
    MaxSub := Br.Bits(3);
    Br.Skip(1); // temporal_id_nesting
    // profile_tier_level(1, MaxSub)
    Br.Skip(2 + 1); // profile_space, tier
    ProfileIdc := Br.Bits(5);
    Br.Skip(32); // compatibility flags
    ProgressiveSrc := Br.Bit;
    InterlacedSrc := Br.Bit;
    Br.Skip(2); // non_packed, frame_only
    Br.Skip(44);
    LevelIdc := Br.Bits(8);
    for I := 0 to MaxSub - 1 do
    begin
      SubProfile[I] := Br.Bit;
      SubLevel[I] := Br.Bit;
    end;
    if MaxSub > 0 then
      for I := MaxSub to 7 do
        Br.Skip(2);
    for I := 0 to MaxSub - 1 do
    begin
      if SubProfile[I] then
        Br.Skip(88);
      if SubLevel[I] then
        Br.Skip(8);
    end;
    Br.UE; // sps id
    Chroma := Br.UE;
    if Chroma = 3 then
      Br.Skip(1);
    W := Br.UE;
    H := Br.UE;
    CL := 0; CR := 0; CT := 0; CB := 0;
    if Br.Bit then
    begin
      CL := Br.UE; CR := Br.UE; CT := Br.UE; CB := Br.UE;
    end;
    SubW := IfThen(Chroma in [1, 2], 2, 1);
    SubH := IfThen(Chroma = 1, 2, 1);
    R.Width := Integer(W) - (CL + CR) * SubW;
    R.Height := Integer(H) - (CT + CB) * SubH;
    R.BitDepth := Integer(Br.UE) + 8;
    R.Interlaced := InterlacedSrc and not ProgressiveSrc;
    case ProfileIdc of
      1: PName := 'Main';
      2: PName := 'Main 10';
      3: PName := 'Main Still';
      4: PName := 'RExt';
    else
      PName := 'Profile ' + IntToStr(ProfileIdc);
    end;
    R.Profile := Format('%s %d.%d', [PName, LevelIdc div 30, (LevelIdc mod 30) div 3]);
    R.VideoCodec := 'HEVC';
    Result := (R.Width > 0) and (R.Height > 0);
  except
    on EConvertError do
      Result := False;
  end;
end;

{ ── TTsAnalyzer ─────────────────────────────────────────────────────────── }

procedure TTsAnalyzer.ResetSync;
begin
  FCarry := nil;
  FSynced := False;
end;

procedure TTsAnalyzer.Feed(const ABuf; ACount: Integer);
var
  Buf: TBytes;
  Off, N: Integer;
begin
  if ACount <= 0 then
    Exit;
  // join with the carried partial packet
  N := Length(FCarry);
  SetLength(Buf, N + ACount);
  if N > 0 then
    Move(FCarry[0], Buf[0], N);
  Move(ABuf, Buf[N], ACount);
  FCarry := nil;
  Off := 0;
  while Off + 188 <= Length(Buf) do
  begin
    if Buf[Off] <> $47 then
      FSynced := False;
    if not FSynced then
    begin
      // need a sync byte here AND one packet later (or at the buffer end)
      if (Buf[Off] = $47) and ((Off + 188 >= Length(Buf)) or (Buf[Off + 188] = $47)) then
        FSynced := True
      else
      begin
        Inc(Off);
        Continue;
      end;
    end;
    Packet(@Buf[Off]);
    Inc(Off, 188);
  end;
  if Off < Length(Buf) then
    FCarry := Copy(Buf, Off, Length(Buf) - Off);
end;

procedure TTsAnalyzer.Packet(const P: PByte);
var
  Pid, Afc, PayOff: Integer;
  Start: Boolean;
begin
  Inc(FBytesTotal, 188);
  Start := (P[1] and $40) <> 0;
  Pid := ((P[1] and $1F) shl 8) or P[2];
  Afc := (P[3] shr 4) and 3;
  if (Afc and 1) = 0 then
    Exit; // no payload
  PayOff := 4;
  if (Afc and 2) <> 0 then
    PayOff := 5 + P[4];
  if PayOff >= 188 then
    Exit;
  if Pid = 0 then
  begin
    if Start and (FPmtPid = 0) then
      ParsePat(@P[PayOff], 188 - PayOff);
  end
  else if (Pid = FPmtPid) and (FPmtPid <> 0) then
  begin
    if Start and not FPmtDone then
      ParsePmt(@P[PayOff], 188 - PayOff);
  end
  else if (Pid = FVideoPid) and (FVideoPid <> 0) then
    VideoPayload(@P[PayOff], 188 - PayOff, Start);
end;

procedure TTsAnalyzer.ParsePat(const P: PByte; ALen: Integer);
var
  Ptr, Off, SecLen, I, Prog: Integer;
begin
  Ptr := P[0];
  Off := 1 + Ptr;
  if Off + 8 > ALen then
    Exit;
  if P[Off] <> 0 then
    Exit; // not a PAT
  SecLen := ((P[Off + 1] and $0F) shl 8) or P[Off + 2];
  I := Off + 8;
  while (I + 4 <= Off + 3 + SecLen - 4) and (I + 4 <= ALen) do
  begin
    Prog := (P[I] shl 8) or P[I + 1];
    if Prog <> 0 then
    begin
      FPmtPid := ((P[I + 2] and $1F) shl 8) or P[I + 3];
      Exit;
    end;
    Inc(I, 4);
  end;
end;

procedure TTsAnalyzer.ParsePmt(const P: PByte; ALen: Integer);
var
  Ptr, Off, SecLen, EndPos, I, PInfo, St, EsPid, EsLen, D, DTag, DLen: Integer;
  Lang, ACodec, Reg: string;
  Au: TProbeAudio;
begin
  Ptr := P[0];
  Off := 1 + Ptr;
  if Off + 12 > ALen then
    Exit;
  if P[Off] <> 2 then
    Exit; // not a PMT
  SecLen := ((P[Off + 1] and $0F) shl 8) or P[Off + 2];
  EndPos := Min(Off + 3 + SecLen - 4, ALen); // before the CRC
  PInfo := ((P[Off + 10] and $0F) shl 8) or P[Off + 11];
  I := Off + 12 + PInfo;
  while I + 5 <= EndPos do
  begin
    St := P[I];
    EsPid := ((P[I + 1] and $1F) shl 8) or P[I + 2];
    EsLen := ((P[I + 3] and $0F) shl 8) or P[I + 4];
    // descriptors: language, AC-3 / E-AC-3 / DTS, registration
    Lang := '';
    ACodec := '';
    Reg := '';
    D := I + 5;
    while (D + 2 <= I + 5 + EsLen) and (D + 2 <= EndPos) do
    begin
      DTag := P[D];
      DLen := P[D + 1];
      if D + 2 + DLen > EndPos then
        Break;
      case DTag of
        $0A: if DLen >= 3 then
               Lang := Chr(P[D + 2]) + Chr(P[D + 3]) + Chr(P[D + 4]);
        $6A: ACodec := 'AC-3';
        $7A: ACodec := 'E-AC-3';
        $7B: ACodec := 'DTS';
        $7C: ACodec := 'AAC';
        $05: if DLen >= 4 then
               Reg := Chr(P[D + 2]) + Chr(P[D + 3]) + Chr(P[D + 4]) + Chr(P[D + 5]);
      end;
      Inc(D, 2 + DLen);
    end;
    case St of
      $01, $02, $1B, $24:
        if FVideoPid = 0 then
        begin
          FVideoPid := EsPid;
          FVideoType := St;
        end;
      $03, $04: ACodec := 'MP2';
      $0F: ACodec := 'AAC';
      $11: ACodec := 'AAC-LATM';
      $81: ACodec := 'AC-3';
      $87: ACodec := 'E-AC-3';
      $06:
        begin
          if (ACodec = '') and (Reg = 'AC-3') then
            ACodec := 'AC-3';
          if (ACodec = '') and (Reg = 'EAC3') then
            ACodec := 'E-AC-3';
          if (FVideoPid = 0) and (Reg = 'HEVC') then
          begin
            FVideoPid := EsPid;
            FVideoType := $24;
          end;
        end;
    else
      ACodec := '';
    end;
    if (ACodec <> '') and (EsPid <> FVideoPid) then
    begin
      Au.Codec := ACodec;
      Au.Language := Lang.Trim;
      FAudio := FAudio + [Au];
    end;
    Inc(I, 5 + EsLen);
  end;
  FPmtDone := True;
end;

procedure TTsAnalyzer.AppendVes(const P: PByte; ALen: Integer);
begin
  if (ALen <= 0) or (FVesLen >= MaxVes) then
    Exit;
  ALen := Min(ALen, MaxVes - FVesLen);
  if FVesLen + ALen > Length(FVes) then
    SetLength(FVes, Max(FVesLen + ALen, Length(FVes) * 2 + 65536));
  Move(P^, FVes[FVesLen], ALen);
  Inc(FVesLen, ALen);
end;

procedure TTsAnalyzer.VideoPayload(const P: PByte; ALen: Integer; AStart: Boolean);
const
  Wrap = Int64(1) shl 33;
var
  HdrLen: Integer;
  Pts: Int64;
begin
  if not AStart then
  begin
    AppendVes(P, ALen);
    Exit;
  end;
  // PES header: 00 00 01 sid len(2) flags(2) hdrlen
  if (ALen < 9) or (P[0] <> 0) or (P[1] <> 0) or (P[2] <> 1) then
    Exit;
  HdrLen := 9 + P[8];
  if ((P[7] and $80) <> 0) and (ALen >= 14) then
  begin
    Pts := (Int64((P[9] shr 1) and 7) shl 30) or (Int64(P[10]) shl 22) or
           (Int64(P[11] shr 1) shl 15) or (Int64(P[12]) shl 7) or Int64(P[13] shr 1);
    if FPtsCount = 0 then
    begin
      FPtsFirst := Pts;
      FPtsMin := Pts;
      FPtsMax := Pts;
      FBytesAtMin := FBytesTotal;
      FBytesAtMax := FBytesTotal;
    end
    else
    begin
      // unwrap the 33-bit clock relative to the first timestamp
      if Pts < FPtsFirst - (Wrap div 2) then
        Inc(Pts, Wrap);
      if Pts < FPtsMin then
      begin
        FPtsMin := Pts;
        if FPtsCount < 3 then
          FBytesAtMin := FBytesTotal;
      end;
      if Pts > FPtsMax then
      begin
        FPtsMax := Pts;
        FBytesAtMax := FBytesTotal;
      end;
    end;
    Inc(FPtsCount);
  end;
  if HdrLen < ALen then
    AppendVes(@P[HdrLen], ALen - HdrLen);
end;

procedure TTsAnalyzer.Finish(var R: TProbeResult);
const
  Mpeg2Rates: array[1..8] of Double = (23.976, 24, 25, 29.97, 30, 50, 59.94, 60);
var
  I, J, NalStart, NalType: Integer;
  Span: Double;
  Nal: TBytes;
  Rate: Integer;
  Got: Boolean;
begin
  R.Audio := FAudio;
  case FVideoType of
    $01: R.VideoCodec := 'MPEG-1';
    $02: R.VideoCodec := 'MPEG-2';
    $1B: R.VideoCodec := 'H.264';
    $24: R.VideoCodec := 'HEVC';
  end;

  // timestamps -> media duration, frame rate, bitrate
  if FPtsCount >= 2 then
  begin
    Span := (FPtsMax - FPtsMin) / 90000;
    if Span > 0 then
    begin
      R.MediaSeconds := Span;
      R.Fps := RoundTo((FPtsCount - 1) / Span, -2);
      if FBytesAtMax > FBytesAtMin then
        R.BitrateKbps := Round((FBytesAtMax - FBytesAtMin) * 8 / Span / 1000);
    end;
  end;

  // hunt the sequence parameters in the collected elementary stream
  Got := False;
  I := 0;
  while (not Got) and (I + 4 < FVesLen) do
  begin
    if (FVes[I] = 0) and (FVes[I + 1] = 0) and (FVes[I + 2] = 1) then
    begin
      NalStart := I + 3;
      // find the next start code (end of this NAL)
      J := NalStart;
      while (J + 3 < FVesLen) and not ((FVes[J] = 0) and (FVes[J + 1] = 0) and
        ((FVes[J + 2] = 1) or ((FVes[J + 2] = 0) and (FVes[J + 3] = 1)))) do
        Inc(J);
      if J + 3 >= FVesLen then
        J := FVesLen;
      case FVideoType of
        $1B:
          begin
            NalType := FVes[NalStart] and $1F;
            if NalType = 7 then
            begin
              Nal := Unescape(@FVes[NalStart], J - NalStart);
              Got := ParseH264Sps(Nal, R);
            end;
          end;
        $24:
          begin
            NalType := (FVes[NalStart] shr 1) and $3F;
            if NalType = 33 then
            begin
              Nal := Unescape(@FVes[NalStart], J - NalStart);
              Got := ParseHevcSps(Nal, R);
            end;
          end;
        $01, $02:
          if (FVes[NalStart] = $B3) and (NalStart + 4 < FVesLen) then
          begin
            R.Width := (FVes[NalStart + 1] shl 4) or (FVes[NalStart + 2] shr 4);
            R.Height := ((FVes[NalStart + 2] and $0F) shl 8) or FVes[NalStart + 3];
            Rate := FVes[NalStart + 4] and $0F;
            if (R.Fps = 0) and (Rate in [1..8]) then
              R.Fps := Mpeg2Rates[Rate];
            R.BitDepth := 8;
            // sequence_extension follows: progressive_sequence bit
            R.Interlaced := True;
            for J := NalStart to Min(FVesLen - 6, NalStart + 200) do
              if (FVes[J] = 0) and (FVes[J + 1] = 0) and (FVes[J + 2] = 1) and
                 (FVes[J + 3] = $B5) and ((FVes[J + 4] shr 4) = 1) then
              begin
                R.Interlaced := ((FVes[J + 5] shr 3) and 1) = 0;
                Break;
              end;
            R.Profile := '';
            Got := True;
          end;
      end;
      I := NalStart;
    end
    else
      Inc(I);
  end;
end;

{ ── fetching ────────────────────────────────────────────────────────────── }

type
  EProbeEnough = class(Exception);

  /// Receives the HTTP body. Sniffs the first bytes: '#EXTM3U' -> buffer the
  /// playlist; otherwise analyze as MPEG-TS and stop after the time budget.
  TProbeSink = class(TStream)
  private
    FAnalyzer: TTsAnalyzer;
    FWatch: TStopwatch;     // started at the request
    FFirstMs: Int64;        // -1 until the first byte
    FMaxMs: Int64;
    FBytes: Int64;
    FSniff: Boolean;
    FIsPlaylist: Boolean;
    FText: TBytesStream;
    FHead: TBytes;          // first bytes of the body (error details)
    FLimitHit: Boolean;
  public
    constructor Create(AAnalyzer: TTsAnalyzer; AMaxMs: Int64; ASniff: Boolean);
    destructor Destroy; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    function PlaylistText: string;
  end;

constructor TProbeSink.Create(AAnalyzer: TTsAnalyzer; AMaxMs: Int64; ASniff: Boolean);
begin
  inherited Create;
  FAnalyzer := AAnalyzer;
  FMaxMs := AMaxMs;
  FFirstMs := -1;
  FSniff := ASniff;
  FText := TBytesStream.Create;
  FWatch := TStopwatch.StartNew;
end;

destructor TProbeSink.Destroy;
begin
  FText.Free;
  inherited;
end;

function TProbeSink.Write(const Buffer; Count: Longint): Longint;
var
  Head: TBytes;
begin
  Result := Count;
  if Count <= 0 then
    Exit;
  if FFirstMs < 0 then
  begin
    FFirstMs := FWatch.ElapsedMilliseconds;
    if FSniff then
    begin
      SetLength(Head, Min(Count, 16));
      Move(Buffer, Head[0], Length(Head));
      // skip a UTF-8 BOM / leading whitespace before #EXTM3U
      FIsPlaylist := Pos('#EXTM3U', TEncoding.ANSI.GetString(Head)) > 0;
    end;
  end;
  if Length(FHead) < 512 then
  begin
    var Keep := Min(Count, 512 - Length(FHead));
    var Old := Length(FHead);
    SetLength(FHead, Old + Keep);
    Move(Buffer, FHead[Old], Keep);
  end;
  Inc(FBytes, Count);
  if FIsPlaylist then
  begin
    if FText.Size + Count > MaxPlaylistBytes then
      raise EProbeEnough.Create('playlist too large');
    FText.WriteBuffer(Buffer, Count);
    Exit;
  end;
  FAnalyzer.Feed(Buffer, Count);
  if (FWatch.ElapsedMilliseconds >= FMaxMs) or (FBytes >= MaxProbeBytes) then
  begin
    FLimitHit := True;
    raise EProbeEnough.Create('enough');
  end;
end;

function TProbeSink.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TProbeSink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FBytes;
end;

function TProbeSink.PlaylistText: string;
begin
  Result := TEncoding.UTF8.GetString(FText.Bytes, 0, FText.Size);
end;

function ResolveUrl(const ABase, ARef: string): string;
var
  U: TIdURI;
begin
  if ContainsText(ARef, '://') then
    Exit(ARef);
  U := TIdURI.Create(ABase);
  try
    if ARef.StartsWith('/') then
      Result := U.Protocol + '://' + U.Host + IfThen(U.Port <> '', ':' + U.Port, '') + ARef
    else
      Result := U.Protocol + '://' + U.Host + IfThen(U.Port <> '', ':' + U.Port, '') +
        U.Path + ARef;
  finally
    U.Free;
  end;
end;

type
  TRedirectCounter = class
    Count: Integer;
    LastUrl: string; // the URL actually served (after the provider's redirects)
    UserAgent: string; // per-source UA ('' = ProbeUA)
    Referer: string;
    procedure OnRedirect(Sender: TObject; var Dest: string; var NumRedirect: Integer;
      var Handled: Boolean; var VMethod: string);
  end;

procedure TRedirectCounter.OnRedirect(Sender: TObject; var Dest: string;
  var NumRedirect: Integer; var Handled: Boolean; var VMethod: string);
begin
  Inc(Count);
  if ContainsText(Dest, '://') then
    LastUrl := Dest
  else if LastUrl <> '' then
    LastUrl := ResolveUrl(LastUrl, Dest);
end;

function NewProbeHttp(ARedir: TRedirectCounter): TIdHTTP;
var
  SSL: TIdSSLIOHandlerSocketOpenSSL;
begin
  Result := TIdHTTP.Create(nil);
  // look like VLC on the wire, not just in the User-Agent: some panels reject
  // anything else (seen: ProviderB answers HTTP 461 to Indy's default headers)
  Result.Request.UserAgent := ProbeUA;
  if (ARedir <> nil) and (ARedir.UserAgent.Trim <> '') then
    Result.Request.UserAgent := ARedir.UserAgent.Trim;
  if (ARedir <> nil) and (ARedir.Referer.Trim <> '') then
    Result.Request.Referer := ARedir.Referer.Trim;
  Result.Request.Accept := '*/*';
  Result.Request.AcceptLanguage := 'en_US';
  Result.Request.Connection := 'close';
  Result.Request.CustomHeaders.AddValue('Range', 'bytes=0-');
  Result.Request.CustomHeaders.AddValue('Icy-MetaData', '1');
  Result.HandleRedirects := True;
  Result.RedirectMaximum := 8;
  Result.ConnectTimeout := 8000;
  Result.ReadTimeout := 8000;
  Result.HTTPOptions := Result.HTTPOptions + [hoNoProtocolErrorException];
  if ARedir <> nil then
    Result.OnRedirect := ARedir.OnRedirect;
  // TLS handler always attached: plain-http portals often redirect to https nodes
  SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
  SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
  Result.IOHandler := SSL;
end;

/// GET AUrl into ASink. Returns the HTTP status (0 = no response); AError holds
/// a transport failure (an EProbeEnough stop is a success). AServer = Server header.
function FetchIntoEx(const AUrl: string; ASink: TProbeSink; ARedir: TRedirectCounter;
  out AFinalUrl, AContentType, AError, AServer: string): Integer;
var
  Http: TIdHTTP;
begin
  AError := '';
  AFinalUrl := AUrl;
  AContentType := '';
  ARedir.LastUrl := AUrl;
  Http := NewProbeHttp(ARedir);
  try
    try
      Http.Get(AUrl, ASink);
      Result := Http.ResponseCode;
    except
      on EProbeEnough do
        Result := Http.ResponseCode;
      on E: Exception do
      begin
        Result := Http.ResponseCode;
        AError := E.Message;
      end;
    end;
    AContentType := Http.Response.ContentType;
    AServer := Http.Response.Server;
    if ARedir.LastUrl <> '' then
      AFinalUrl := ARedir.LastUrl;
  finally
    Http.Free;
  end;
end;

/// GET AUrl into ASink. Returns the HTTP status; ERROR text on transport failure
/// (an EProbeEnough stop is a success).
function FetchInto(const AUrl: string; ASink: TProbeSink; ARedir: TRedirectCounter;
  out AFinalUrl, AContentType, AError: string): Integer;
var
  LServer: string;
begin
  Result := FetchIntoEx(AUrl, ASink, ARedir, AFinalUrl, AContentType, AError, LServer);
end;

function AttrValue(const ALine, AName: string): string;
var
  P, E: Integer;
begin
  Result := '';
  P := Pos(AName + '=', UpperCase(ALine));
  if P = 0 then
    Exit;
  Inc(P, Length(AName) + 1);
  if (P <= Length(ALine)) and (ALine[P] = '"') then
  begin
    E := PosEx('"', ALine, P + 1);
    if E = 0 then
      E := Length(ALine) + 1;
    Result := Copy(ALine, P + 1, E - P - 1);
  end
  else
  begin
    E := PosEx(',', ALine, P);
    if E = 0 then
      E := Length(ALine) + 1;
    Result := Copy(ALine, P, E - P);
  end;
end;

procedure ApplyHlsCodecs(const ACodecs, AResolution: string; var R: TProbeResult);
var
  C: string;
  Au: TProbeAudio;
  X: Integer;
begin
  for C in ACodecs.Split([',']) do
  begin
    if StartsText('avc1', C.Trim) and (R.VideoCodec = '') then R.VideoCodec := 'H.264';
    if (StartsText('hvc1', C.Trim) or StartsText('hev1', C.Trim)) and (R.VideoCodec = '') then
      R.VideoCodec := 'HEVC';
    if (Length(R.Audio) = 0) then
    begin
      Au.Language := '';
      Au.Codec := '';
      if StartsText('mp4a', C.Trim) then Au.Codec := 'AAC';
      if StartsText('ac-3', C.Trim) then Au.Codec := 'AC-3';
      if StartsText('ec-3', C.Trim) then Au.Codec := 'E-AC-3';
      if Au.Codec <> '' then
        R.Audio := [Au];
    end;
  end;
  X := Pos('X', UpperCase(AResolution));
  if (R.Width = 0) and (X > 0) then
  begin
    R.Width := StrToIntDef(Copy(AResolution, 1, X - 1), 0);
    R.Height := StrToIntDef(Copy(AResolution, X + 1, MaxInt), 0);
  end;
end;

procedure ProbeHls(const APlaylist, ABaseUrl: string; AAnalyzer: TTsAnalyzer;
  ARedir: TRedirectCounter; AWatch: TStopwatch; AMaxMs: Int64; var R: TProbeResult);
var
  Lines, Segs: TArray<string>;
  Line, Url, Text, FinalUrl, Ct, Err, Codecs, Resol: string;
  I, Best, Bw, Code, K, Start: Integer;
  Sink: TProbeSink;
  Fmp4: Boolean;
  Wall: TStopwatch;
begin
  R.Container := 'hls';
  Codecs := '';
  Resol := '';
  Text := APlaylist;
  Url := ABaseUrl;
  // master playlist -> the highest-bandwidth variant
  if ContainsText(Text, '#EXT-X-STREAM-INF') then
  begin
    Lines := Text.Split([#10]);
    Best := -1;
    Url := '';
    for I := 0 to High(Lines) do
    begin
      Line := Lines[I].Trim;
      if StartsText('#EXT-X-STREAM-INF', Line) then
      begin
        Bw := StrToIntDef(AttrValue(Line, 'BANDWIDTH'), 0);
        if (Bw > Best) and (I < High(Lines)) then
        begin
          Best := Bw;
          Codecs := AttrValue(Line, 'CODECS');
          Resol := AttrValue(Line, 'RESOLUTION');
          K := I + 1;
          while (K <= High(Lines)) and ((Lines[K].Trim = '') or Lines[K].Trim.StartsWith('#')) do
            Inc(K);
          if K <= High(Lines) then
            Url := ResolveUrl(ABaseUrl, Lines[K].Trim);
        end;
      end;
    end;
    ApplyHlsCodecs(Codecs, Resol, R);
    if Url = '' then
    begin
      R.Error := 'HLS master playlist without variants';
      Exit;
    end;
    Sink := TProbeSink.Create(AAnalyzer, 15000, True);
    try
      Code := FetchInto(Url, Sink, ARedir, FinalUrl, Ct, Err);
      if ((Code <> 200) and (Code <> 206)) or not Sink.FIsPlaylist then
      begin
        R.Error := IfThen(Err <> '', Err, Format('HLS variant playlist: HTTP %d', [Code]));
        Exit;
      end;
      Text := Sink.PlaylistText;
      Url := FinalUrl;
    finally
      Sink.Free;
    end;
  end;

  // media playlist: segment URIs; take the newest few (live edge)
  Fmp4 := ContainsText(Text, '#EXT-X-MAP');
  Segs := [];
  for Line in Text.Split([#10]) do
    if (Line.Trim <> '') and not Line.Trim.StartsWith('#') then
      Segs := Segs + [ResolveUrl(Url, Line.Trim)];
  if Length(Segs) = 0 then
  begin
    R.Error := 'HLS playlist without segments';
    Exit;
  end;
  if Fmp4 then
  begin
    R.Container := 'hls-fmp4';
    R.Ok := R.VideoCodec <> '';
    if not R.Ok then
      R.Error := 'fMP4 HLS: only the playlist could be read';
    Exit;
  end;
  Start := Max(0, Length(Segs) - 3);
  Wall := TStopwatch.StartNew;
  for I := Start to High(Segs) do
  begin
    if AWatch.ElapsedMilliseconds >= AMaxMs then
      Break;
    AAnalyzer.ResetSync;
    Sink := TProbeSink.Create(AAnalyzer, 30000, False);
    try
      Code := FetchInto(Segs[I], Sink, ARedir, FinalUrl, Ct, Err);
      Inc(R.Bytes, Sink.FBytes);
      if (Code <> 200) and (Code <> 206) then
      begin
        R.Error := IfThen(Err <> '', Err, Format('HLS segment: HTTP %d', [Code]));
        Break;
      end;
    finally
      Sink.Free;
    end;
  end;
  R.WallSeconds := Wall.ElapsedMilliseconds / 1000;
end;

/// 'HTTP 461 (server nginx): <the provider's own text>' — tags stripped,
/// whitespace collapsed, at most 200 chars; credentials never appear in a body.
function HttpErrorText(ACode: Integer; const AServer: string; const ABody: TBytes): string;
var
  Txt: string;
  Ch: Char;
  InTag: Boolean;
  Sb: TStringBuilder;
begin
  Result := Format('HTTP %d', [ACode]);
  if AServer.Trim <> '' then
    Result := Result + ' (' + AServer.Trim + ')';
  if Length(ABody) = 0 then
    Exit;
  Txt := TEncoding.UTF8.GetString(ABody);
  Sb := TStringBuilder.Create;
  try
    InTag := False;
    for Ch in Txt do
      if Ch = '<' then
        InTag := True
      else if Ch = '>' then
      begin
        InTag := False;
        Sb.Append(' ');
      end
      else if not InTag then
        if Ord(Ch) <= 32 then // control chars / whitespace
          Sb.Append(' ')
        else
          Sb.Append(Ch);
    Txt := Sb.ToString;
  finally
    Sb.Free;
  end;
  while Pos('  ', Txt) > 0 do
    Txt := StringReplace(Txt, '  ', ' ', [rfReplaceAll]);
  Txt := Txt.Trim;
  if Length(Txt) > 200 then
    Txt := Copy(Txt, 1, 200) + '...';
  if Txt <> '' then
    Result := Result + ': ' + Txt;
end;

function ProbeStream(const AUrl: string; AMaxSeconds: Integer;
  const AUserAgent, AReferer: string): TProbeResult;
var
  Analyzer: TTsAnalyzer;
  Sink: TProbeSink;
  Redir: TRedirectCounter;
  Watch: TStopwatch;
  Code: Integer;
  FinalUrl, Ct, Err, Server: string;
  MaxMs: Int64;
begin
  Result := Default(TProbeResult);
  if AUrl.Trim = '' then
  begin
    Result.Error := 'no stream URL';
    Exit;
  end;
  MaxMs := EnsureRange(AMaxSeconds, 3, 20) * 1000;
  GProbeLock.Acquire;
  try
    Analyzer := TTsAnalyzer.Create;
    Redir := TRedirectCounter.Create;
    Redir.UserAgent := AUserAgent;
    Redir.Referer := AReferer;
    try
      try
        Watch := TStopwatch.StartNew;
        Sink := TProbeSink.Create(Analyzer, MaxMs, True);
        try
          Code := FetchIntoEx(AUrl, Sink, Redir, FinalUrl, Ct, Err, Server);
          // a refusal (connection limit / anti-flood: 429, 458, 461, 503, ...) is
          // often transient right after another connection closed: retry once
          if (Code = 429) or (Code = 458) or (Code = 461) or (Code = 503) then
          begin
            Sink.Free;
            Sink := nil;
            Analyzer.Free;
            Analyzer := TTsAnalyzer.Create;
            Sleep(5000);
            Redir.Count := 0;
            Watch := TStopwatch.StartNew;
            Sink := TProbeSink.Create(Analyzer, MaxMs, True);
            Code := FetchIntoEx(AUrl, Sink, Redir, FinalUrl, Ct, Err, Server);
          end;
          Result.FirstByteMs := Max(0, Integer(Sink.FFirstMs));
          Result.Bytes := Sink.FBytes;
          if Sink.FFirstMs >= 0 then
            Result.WallSeconds := (Watch.ElapsedMilliseconds - Sink.FFirstMs) / 1000;
          if (Code >= 400) or ((Code = 0) and (Sink.FBytes = 0)) then
          begin
            if Code >= 400 then
              Result.Error := HttpErrorText(Code, Server, Sink.FHead)
            else
              Result.Error := IfThen(Err <> '', Err, 'no response');
            Exit;
          end;
          if Sink.FIsPlaylist then
            ProbeHls(Sink.PlaylistText, FinalUrl, Analyzer, Redir, Watch, MaxMs, Result)
          else
          begin
            Result.Container := 'mpegts';
            if (Err <> '') and (Analyzer.BytesTotal > 0) then
              Result.Error := 'stalled: ' + Err  // got data, then the server stopped
            else if Err <> '' then
              Result.Error := Err
            else if (not Sink.FLimitHit) and (Analyzer.BytesTotal > 0) then
              Result.Error := 'stream ended early';
            if (Analyzer.BytesTotal = 0) and (Sink.FBytes > 0) then
            begin
              Result.Container := IfThen(Ct <> '', Ct, 'unknown');
              Result.Error := 'not an MPEG-TS stream (' + Result.Container + ')';
              Exit;
            end;
          end;
        finally
          Sink.Free;
        end;
        if Result.Container <> 'hls-fmp4' then
        begin
          Analyzer.Finish(Result);
          if Result.Container = 'hls' then
            Result.Bytes := Analyzer.BytesTotal;
          Result.Ok := (Result.VideoCodec <> '') or (Length(Result.Audio) > 0);
          if (not Result.Ok) and (Result.Error = '') then
            Result.Error := 'no video found in the stream';
        end;
        Result.Redirects := Redir.Count;
      except
        on E: Exception do
        begin
          Result.Ok := False;
          Result.Error := E.Message;
        end;
      end;
    finally
      Redir.Free;
      Analyzer.Free;
    end;
  finally
    GProbeLock.Release;
  end;
end;

initialization
  GProbeLock := TCriticalSection.Create;

finalization
  GProbeLock.Free;

end.
