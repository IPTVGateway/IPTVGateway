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
  // RTL
  System.SysUtils,
  System.Classes;

type
  /// One audio track found in the stream.
  TProbeAudio = record
    Codec: string;     // 'AAC', 'AC-3', 'E-AC-3', 'MP2', ...
    Language: string;  // ISO 639 code from the PMT ('' if none)
  end;

  /// Outcome of one stream probe (media facts + transfer timings).
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
    procedure Packet(const APacket: PByte);
    procedure ParsePat(const AData: PByte; ALen: Integer);
    procedure ParsePmt(const AData: PByte; ALen: Integer);
    procedure VideoPayload(const AData: PByte; ALen: Integer; AStart: Boolean);
    procedure AppendVes(const AData: PByte; ALen: Integer);
  public
    /// Parse ACount raw TS bytes; partial packets are carried to the next call.
    procedure Feed(const ABuf; ACount: Integer);
    /// Drop any partial packet (call between HLS segments).
    procedure ResetSync;
    /// Fill the media fields of R from what was seen.
    procedure Finish(var AResult: TProbeResult);
    /// TS bytes parsed so far (whole packets).
    property BytesTotal: Int64 read FBytesTotal;
  end;

const
  /// Default receive budget of a probe, in seconds.
  cProbeDefaultSeconds = 8;

/// Probe a stream URL for at most AMaxSeconds of receiving (clamped 3..20).
/// Never raises; failures come back as Ok=False + Error.
/// AUserAgent / AReferer: the source's own settings ('' = VLC default UA).
function ProbeStream(const AUrl: string; AMaxSeconds: Integer = cProbeDefaultSeconds;
  const AUserAgent: string = ''; const AReferer: string = ''): TProbeResult;

// exposed for tests
/// Parse an H.264 SPS NAL (incl. its 1-byte header) into AResult; False if unreadable.
function ParseH264Sps(const ANal: TBytes; var AResult: TProbeResult): Boolean;
/// Parse an HEVC SPS NAL (incl. its 2-byte header) into AResult; False if unreadable.
function ParseHevcSps(const ANal: TBytes; var AResult: TProbeResult): Boolean;

implementation

uses
  // RTL
  System.SyncObjs,
  System.Diagnostics,
  System.Math,
  System.StrUtils,
  System.Generics.Collections,
  // Indy
  IdHTTP,
  IdSSLOpenSSL,
  IdURI;

const
  // HTTP client: look like VLC on the wire
  cProbeUserAgent = 'VLC/3.0.21 LibVLC/3.0.21'; // default when the source sets no UA
  cAcceptAny = '*/*';
  cAcceptLanguage = 'en_US';
  cConnectionClose = 'close';
  cHeaderRange = 'Range';
  cRangeFromStart = 'bytes=0-';
  cHeaderIcyMetaData = 'Icy-MetaData';
  cIcyMetaDataOn = '1';
  cMaxRedirects = 8;
  cTimeoutConnectMs = 8000;
  cTimeoutReadMs = 8000;
  cSchemeSeparator = '://';

  // HTTP status codes
  cHttpStatusOk = 200;
  cHttpStatusPartialContent = 206;
  cHttpStatusErrorMin = 400;
  // a refusal (connection limit / anti-flood) that is often transient right
  // after another connection closed: 429 Too Many Requests, 458 / 461 (panel
  // specific), 503 Service Unavailable -> retry once after cRefusalRetryDelayMs
  cRefusalStatuses: array[0..3] of Integer = (429, 458, 461, 503);
  cRefusalRetryDelayMs = 5000;

  // probe budget
  cProbeMinSeconds = 3;
  cProbeMaxSeconds = 20;
  cMaxVesBytes = 1024 * 1024;          // video ES kept for SPS hunting
  cVesGrowBytes = 65536;               // minimum growth of the ES buffer
  cMaxProbeBytes = 64 * 1024 * 1024;
  cMaxPlaylistBytes = 1024 * 1024;
  cSniffBytes = 16;                    // body head checked for #EXTM3U
  // TProbeSink.Create ASniff: detect an HLS playlist in the body, or always analyze as TS
  cSniffPlaylist = True;
  cNoSniff = False;
  cErrorHeadBytes = 512;               // body head kept for error details
  cErrorTextMaxLen = 200;

  // HLS
  cHlsHeader = '#EXTM3U';
  cHlsTagStreamInf = '#EXT-X-STREAM-INF';
  cHlsTagMap = '#EXT-X-MAP';           // fMP4 init segment
  cHlsAttrBandwidth = 'BANDWIDTH';
  cHlsAttrCodecs = 'CODECS';
  cHlsAttrResolution = 'RESOLUTION';
  // RFC 6381 codec prefixes in the CODECS attribute
  cHlsCodecAvc1 = 'avc1';
  cHlsCodecHvc1 = 'hvc1';
  cHlsCodecHev1 = 'hev1';
  cHlsCodecMp4a = 'mp4a';
  cHlsCodecAc3 = 'ac-3';
  cHlsCodecEc3 = 'ec-3';
  cHlsVariantBudgetMs = 15000;         // fetching the variant playlist
  cHlsSegmentBudgetMs = 30000;         // fetching one media segment
  cHlsLiveEdgeSegments = 3;            // newest segments analysed

  // containers reported in TProbeResult.Container
  cContainerMpegTs = 'mpegts';
  cContainerHls = 'hls';
  cContainerHlsFmp4 = 'hls-fmp4';

  // codec names reported
  cCodecH264 = 'H.264';
  cCodecHevc = 'HEVC';
  cCodecMpeg1 = 'MPEG-1';
  cCodecMpeg2 = 'MPEG-2';
  cCodecAac = 'AAC';
  cCodecAacLatm = 'AAC-LATM';
  cCodecAc3 = 'AC-3';
  cCodecEac3 = 'E-AC-3';
  cCodecDts = 'DTS';
  cCodecMp2 = 'MP2';

  // MPEG-TS packet
  cTsPacketSize = 188;
  cTsSyncByte = $47;
  cTsHeaderSize = 4;
  cTsPayloadStartFlag = $40;           // byte 1: payload_unit_start_indicator
  cTsPidHighMask = $1F;                // byte 1: top 5 bits of the 13-bit PID
  cTsAfcMask = 3;                      // byte 3 bits 5..4: adaptation_field_control
  cTsAfcShift = 4;
  cTsAfcPayload = 1;
  cTsAfcAdaptation = 2;
  cTsPidPat = 0;

  // PSI sections (PAT / PMT)
  cPsiTableIdPat = $00;
  cPsiTableIdPmt = $02;
  cPsiLengthHighMask = $0F;            // 12-bit section / info / ES-info lengths
  cPsiSectionHeaderSize = 3;           // table_id + section_length
  cPsiCrcSize = 4;
  cPatHeaderSize = 8;
  cPatEntrySize = 4;                   // program_number + PMT PID
  cPmtHeaderSize = 12;
  cPmtEsHeaderSize = 5;                // stream_type + PID + ES_info_length
  cDescHeaderSize = 2;                 // tag + length

  // PMT descriptor tags
  cDescRegistration = $05;
  cDescIso639Language = $0A;
  cDescAc3 = $6A;
  cDescEac3 = $7A;
  cDescDts = $7B;
  cDescAac = $7C;
  cIso639CodeLen = 3;
  cRegFormatIdLen = 4;

  // registration format identifiers (stream type $06)
  cRegFormatAc3 = 'AC-3';
  cRegFormatEac3 = 'EAC3';
  cRegFormatHevc = 'HEVC';

  // PMT stream types
  cStreamTypeMpeg1Video = $01;
  cStreamTypeMpeg2Video = $02;
  cStreamTypeMpeg1Audio = $03;
  cStreamTypeMpeg2Audio = $04;
  cStreamTypePrivatePes = $06;
  cStreamTypeAacAdts = $0F;
  cStreamTypeAacLatm = $11;
  cStreamTypeH264 = $1B;
  cStreamTypeHevc = $24;
  cStreamTypeAc3 = $81;
  cStreamTypeEac3 = $87;

  // PES header: 00 00 01 sid len(2) flags(2) hdrlen
  cPesHeaderSize = 9;
  cPesHeaderLenOffset = 8;
  cPesFlagsOffset = 7;
  cPesPtsFlag = $80;
  cPesPtsOffset = 9;
  cPesWithPtsSize = 14;                // header + 5-byte PTS
  cPtsClockHz = 90000;
  cPtsWrap = Int64(1) shl 33;          // 33-bit PTS clock
  cPtsEarlySamples = 3;                // first PTS that may still lower the byte base

  // elementary stream start codes / NAL units
  cEmulationPreventionByte = $03;      // 00 00 03 -> 00 00
  cStartCodeSize = 3;                  // 00 00 01
  cH264NalTypeMask = $1F;
  cH264NalSps = 7;
  cH264NalHeaderBits = 8;
  cHevcNalTypeMask = $3F;
  cHevcNalTypeShift = 1;
  cHevcNalSps = 33;
  cHevcNalHeaderBits = 16;
  cMpeg2SequenceHeader = $B3;
  cMpeg2ExtensionStart = $B5;
  cMpeg2SequenceExtId = 1;             // extension_start_code_identifier
  cMpeg2FrameRateMask = $0F;
  cMpeg2ExtScanBytes = 200;            // sequence_extension follows the header closely
  cMpeg2FrameRates: array[1..8] of Double = (23.976, 24, 25, 29.97, 30, 50, 59.94, 60);

  // SPS fields
  cExpGolombMaxZeros = 31;
  cBitDepthBase = 8;                   // bit_depth_minus8 + 8
  cMbSize = 16;                        // H.264 macroblock size in luma samples
  cChroma400 = 0;
  cChroma420 = 1;
  cChroma422 = 2;
  cChroma444 = 3;
  // H.264 profiles that carry chroma_format_idc / bit depth / scaling lists
  cH264HighProfiles = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135];
  cH264ProfileBaseline = 66;
  cH264ProfileMain = 77;
  cH264ProfileExtended = 88;
  cH264ProfileHigh = 100;
  cH264ProfileHigh10 = 110;
  cH264ProfileHigh422 = 122;
  cH264ProfileHigh444 = 244;
  cH264LevelDivisor = 10;              // level_idc 40 = 4.0
  cScalingListCount = 8;
  cScalingListCount444 = 12;
  cScalingList4x4Count = 6;
  cScalingList4x4Size = 16;
  cScalingList8x8Size = 64;
  cScalingDefault = 8;
  cScalingModulo = 256;
  cHevcProfileMain = 1;
  cHevcProfileMain10 = 2;
  cHevcProfileMainStill = 3;
  cHevcProfileRext = 4;
  cHevcLevelDivisor = 30;              // general_level_idc 153 = 5.1
  cHevcLevelMinorDivisor = 3;
  cHevcMaxSubLayers = 8;
  cHevcCompatFlagsBits = 32;
  cHevcConstraintFlagsBits = 44;       // remaining general constraint flags
  cHevcSubLayerProfileBits = 88;
  cHevcSubLayerLevelBits = 8;

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
    function Bits(ACount: Integer): Cardinal;
    function Bit: Boolean;
    function UE: Cardinal;
    function SE: Integer;
    procedure Skip(ACount: Integer);
    function Eof: Boolean;
  end;

function TBitReader.Bits(ACount: Integer): Cardinal;
var
  i, lBit: Integer;
begin
  Result := 0;
  for i := 1 to ACount do
  begin
    if (Pos shr 3) >= Length(Data) then
      raise EConvertError.Create('SPS truncated');
    lBit := (Data[Pos shr 3] shr (7 - (Pos and 7))) and 1;
    Result := (Result shl 1) or Cardinal(lBit);
    Inc(Pos);
  end;
end;

function TBitReader.Bit: Boolean;
begin
  Result := Bits(1) = 1;
end;

function TBitReader.UE: Cardinal;
var
  lZeros: Integer;
begin
  lZeros := 0;
  while not Bit do
  begin
    Inc(lZeros);
    if lZeros > cExpGolombMaxZeros then
      raise EConvertError.Create('bad exp-golomb');
  end;
  if lZeros = 0 then
    Exit(0);
  Result := (Cardinal(1) shl lZeros) - 1 + Bits(lZeros);
end;

function TBitReader.SE: Integer;
var
  lValue: Cardinal;
begin
  lValue := UE;
  if Odd(lValue) then
    Result := Integer((lValue + 1) div 2)
  else
    Result := -Integer(lValue div 2);
end;

procedure TBitReader.Skip(ACount: Integer);
begin
  Inc(Pos, ACount);
end;

function TBitReader.Eof: Boolean;
begin
  Result := (Pos shr 3) >= Length(Data);
end;

// strip the 0x03 emulation-prevention bytes (00 00 03 -> 00 00)
function Unescape(const AData: PByte; ALen: Integer): TBytes;
var
  i, lLen, lZeros: Integer;
  lByte: Byte;
begin
  SetLength(Result, ALen);
  lLen := 0;
  lZeros := 0;
  for i := 0 to ALen - 1 do
  begin
    lByte := AData[i];
    if (lZeros >= 2) and (lByte = cEmulationPreventionByte) then
    begin
      lZeros := 0;
      Continue;
    end;
    if lByte = 0 then
      Inc(lZeros)
    else
      lZeros := 0;
    Result[lLen] := lByte;
    Inc(lLen);
  end;
  SetLength(Result, lLen);
end;

{ ── SPS parsers ─────────────────────────────────────────────────────────── }

function ParseH264Sps(const ANal: TBytes; var AResult: TProbeResult): Boolean;
var
  lReader: TBitReader;
  lProfileIdc, lLevelIdc, lChroma, lPocType, i, j, lCount, lSizeOfList: Integer;
  lLastScale, lNextScale: Integer;
  lWidthMbs, lHeightMapUnits: Cardinal;
  lFrameMbsOnly: Boolean;
  lCropLeft, lCropRight, lCropTop, lCropBottom, lCropUnitX, lCropUnitY: Integer;
  lProfileName: string;
begin
  // ANal = full NAL incl. its 1-byte header
  lReader.Data := ANal;
  lReader.Pos := cH264NalHeaderBits;
  try
    lProfileIdc := lReader.Bits(8);
    lReader.Skip(8); // constraint flags
    lLevelIdc := lReader.Bits(8);
    lReader.UE; // sps id
    lChroma := cChroma420;
    AResult.BitDepth := cBitDepthBase;
    if lProfileIdc in cH264HighProfiles then
    begin
      lChroma := lReader.UE;
      if lChroma = cChroma444 then
        lReader.Skip(1); // separate_colour_plane
      AResult.BitDepth := Integer(lReader.UE) + cBitDepthBase;
      lReader.UE; // bit_depth_chroma
      lReader.Skip(1); // qpprime_y_zero_transform_bypass
      if lReader.Bit then // seq_scaling_matrix_present
      begin
        lCount := IfThen(lChroma <> cChroma444, cScalingListCount, cScalingListCount444);
        for i := 0 to lCount - 1 do
          if lReader.Bit then
          begin
            lSizeOfList := IfThen(i < cScalingList4x4Count, cScalingList4x4Size, cScalingList8x8Size);
            lLastScale := cScalingDefault;
            lNextScale := cScalingDefault;
            for j := 0 to lSizeOfList - 1 do
            begin
              if lNextScale <> 0 then
                lNextScale := (lLastScale + lReader.SE + cScalingModulo) mod cScalingModulo;
              if lNextScale <> 0 then
                lLastScale := lNextScale;
            end;
          end;
      end;
    end;
    lReader.UE; // log2_max_frame_num_minus4
    lPocType := lReader.UE;
    if lPocType = 0 then
      lReader.UE
    else if lPocType = 1 then
    begin
      lReader.Skip(1);
      lReader.SE;
      lReader.SE;
      lCount := lReader.UE;
      for i := 1 to lCount do
        lReader.SE;
    end;
    lReader.UE; // max_num_ref_frames
    lReader.Skip(1); // gaps_in_frame_num_allowed
    lWidthMbs := lReader.UE;
    lHeightMapUnits := lReader.UE;
    lFrameMbsOnly := lReader.Bit;
    if not lFrameMbsOnly then
      lReader.Skip(1); // mb_adaptive_frame_field
    lReader.Skip(1); // direct_8x8_inference
    lCropLeft := 0;
    lCropRight := 0;
    lCropTop := 0;
    lCropBottom := 0;
    if lReader.Bit then
    begin
      lCropLeft := lReader.UE;
      lCropRight := lReader.UE;
      lCropTop := lReader.UE;
      lCropBottom := lReader.UE;
    end;
    case lChroma of
      cChroma400:
        begin
          lCropUnitX := 1;
          lCropUnitY := 2 - Ord(lFrameMbsOnly);
        end;
      cChroma420:
        begin
          lCropUnitX := 2;
          lCropUnitY := 2 * (2 - Ord(lFrameMbsOnly));
        end;
      cChroma422:
        begin
          lCropUnitX := 2;
          lCropUnitY := 2 - Ord(lFrameMbsOnly);
        end;
    else
      lCropUnitX := 1;
      lCropUnitY := 2 - Ord(lFrameMbsOnly);
    end;
    AResult.Width := Integer(lWidthMbs + 1) * cMbSize - (lCropLeft + lCropRight) * lCropUnitX;
    AResult.Height := (2 - Ord(lFrameMbsOnly)) * Integer(lHeightMapUnits + 1) * cMbSize -
      (lCropTop + lCropBottom) * lCropUnitY;
    AResult.Interlaced := not lFrameMbsOnly;
    case lProfileIdc of
      cH264ProfileBaseline: lProfileName := 'Baseline';
      cH264ProfileMain: lProfileName := 'Main';
      cH264ProfileExtended: lProfileName := 'Extended';
      cH264ProfileHigh: lProfileName := 'High';
      cH264ProfileHigh10: lProfileName := 'High 10';
      cH264ProfileHigh422: lProfileName := 'High 4:2:2';
      cH264ProfileHigh444: lProfileName := 'High 4:4:4';
    else
      lProfileName := 'Profile ' + IntToStr(lProfileIdc);
    end;
    AResult.Profile := Format('%s %d.%d', [lProfileName, lLevelIdc div cH264LevelDivisor,
      lLevelIdc mod cH264LevelDivisor]);
    AResult.VideoCodec := cCodecH264;
    Result := (AResult.Width > 0) and (AResult.Height > 0);
  except
    on EConvertError do
      Result := False;
  end;
end;

function ParseHevcSps(const ANal: TBytes; var AResult: TProbeResult): Boolean;
var
  lReader: TBitReader;
  lMaxSub, i, lProfileIdc, lLevelIdc, lChroma: Integer;
  lProgressiveSrc, lInterlacedSrc: Boolean;
  lSubProfile, lSubLevel: array[0..cHevcMaxSubLayers - 1] of Boolean;
  lWidth, lHeight: Cardinal;
  lCropLeft, lCropRight, lCropTop, lCropBottom, lSubW, lSubH: Integer;
  lProfileName: string;
begin
  lReader.Data := ANal;
  lReader.Pos := cHevcNalHeaderBits; // 2-byte NAL header
  try
    lReader.Skip(4); // vps id
    lMaxSub := lReader.Bits(3);
    lReader.Skip(1); // temporal_id_nesting
    // profile_tier_level(1, MaxSub)
    lReader.Skip(2 + 1); // profile_space, tier
    lProfileIdc := lReader.Bits(5);
    lReader.Skip(cHevcCompatFlagsBits); // compatibility flags
    lProgressiveSrc := lReader.Bit;
    lInterlacedSrc := lReader.Bit;
    lReader.Skip(2); // non_packed, frame_only
    lReader.Skip(cHevcConstraintFlagsBits);
    lLevelIdc := lReader.Bits(8);
    for i := 0 to lMaxSub - 1 do
    begin
      lSubProfile[i] := lReader.Bit;
      lSubLevel[i] := lReader.Bit;
    end;
    if lMaxSub > 0 then
      for i := lMaxSub to cHevcMaxSubLayers - 1 do
        lReader.Skip(2);
    for i := 0 to lMaxSub - 1 do
    begin
      if lSubProfile[i] then
        lReader.Skip(cHevcSubLayerProfileBits);
      if lSubLevel[i] then
        lReader.Skip(cHevcSubLayerLevelBits);
    end;
    lReader.UE; // sps id
    lChroma := lReader.UE;
    if lChroma = cChroma444 then
      lReader.Skip(1);
    lWidth := lReader.UE;
    lHeight := lReader.UE;
    lCropLeft := 0;
    lCropRight := 0;
    lCropTop := 0;
    lCropBottom := 0;
    if lReader.Bit then
    begin
      lCropLeft := lReader.UE;
      lCropRight := lReader.UE;
      lCropTop := lReader.UE;
      lCropBottom := lReader.UE;
    end;
    lSubW := IfThen(lChroma in [cChroma420, cChroma422], 2, 1);
    lSubH := IfThen(lChroma = cChroma420, 2, 1);
    AResult.Width := Integer(lWidth) - (lCropLeft + lCropRight) * lSubW;
    AResult.Height := Integer(lHeight) - (lCropTop + lCropBottom) * lSubH;
    AResult.BitDepth := Integer(lReader.UE) + cBitDepthBase;
    AResult.Interlaced := lInterlacedSrc and not lProgressiveSrc;
    case lProfileIdc of
      cHevcProfileMain: lProfileName := 'Main';
      cHevcProfileMain10: lProfileName := 'Main 10';
      cHevcProfileMainStill: lProfileName := 'Main Still';
      cHevcProfileRext: lProfileName := 'RExt';
    else
      lProfileName := 'Profile ' + IntToStr(lProfileIdc);
    end;
    AResult.Profile := Format('%s %d.%d', [lProfileName, lLevelIdc div cHevcLevelDivisor,
      (lLevelIdc mod cHevcLevelDivisor) div cHevcLevelMinorDivisor]);
    AResult.VideoCodec := cCodecHevc;
    Result := (AResult.Width > 0) and (AResult.Height > 0);
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
  lBuf: TBytes;
  lOff, lLen: Integer;
begin
  if ACount <= 0 then
    Exit;
  // join with the carried partial packet
  lLen := Length(FCarry);
  SetLength(lBuf, lLen + ACount);
  if lLen > 0 then
    Move(FCarry[0], lBuf[0], lLen);
  Move(ABuf, lBuf[lLen], ACount);
  FCarry := nil;
  lOff := 0;
  while lOff + cTsPacketSize <= Length(lBuf) do
  begin
    if lBuf[lOff] <> cTsSyncByte then
      FSynced := False;
    if not FSynced then
    begin
      // need a sync byte here AND one packet later (or at the buffer end)
      if (lBuf[lOff] = cTsSyncByte) and ((lOff + cTsPacketSize >= Length(lBuf)) or
        (lBuf[lOff + cTsPacketSize] = cTsSyncByte)) then
        FSynced := True
      else
      begin
        Inc(lOff);
        Continue;
      end;
    end;
    Packet(@lBuf[lOff]);
    Inc(lOff, cTsPacketSize);
  end;
  if lOff < Length(lBuf) then
    FCarry := Copy(lBuf, lOff, Length(lBuf) - lOff);
end;

procedure TTsAnalyzer.Packet(const APacket: PByte);
var
  lPid, lAfc, lPayOff: Integer;
  lStart: Boolean;
begin
  Inc(FBytesTotal, cTsPacketSize);
  lStart := (APacket[1] and cTsPayloadStartFlag) <> 0;
  lPid := ((APacket[1] and cTsPidHighMask) shl 8) or APacket[2];
  lAfc := (APacket[3] shr cTsAfcShift) and cTsAfcMask;
  if (lAfc and cTsAfcPayload) = 0 then
    Exit; // no payload
  lPayOff := cTsHeaderSize;
  if (lAfc and cTsAfcAdaptation) <> 0 then
    lPayOff := cTsHeaderSize + 1 + APacket[cTsHeaderSize]; // adaptation_field_length byte
  if lPayOff >= cTsPacketSize then
    Exit;
  if lPid = cTsPidPat then
  begin
    if lStart and (FPmtPid = 0) then
      ParsePat(@APacket[lPayOff], cTsPacketSize - lPayOff);
  end
  else if (lPid = FPmtPid) and (FPmtPid <> 0) then
  begin
    if lStart and not FPmtDone then
      ParsePmt(@APacket[lPayOff], cTsPacketSize - lPayOff);
  end
  else if (lPid = FVideoPid) and (FVideoPid <> 0) then
    VideoPayload(@APacket[lPayOff], cTsPacketSize - lPayOff, lStart);
end;

procedure TTsAnalyzer.ParsePat(const AData: PByte; ALen: Integer);
var
  lPointer, lOff, lSecLen, lPos, lProgram: Integer;
begin
  lPointer := AData[0];
  lOff := 1 + lPointer;
  if lOff + cPatHeaderSize > ALen then
    Exit;
  if AData[lOff] <> cPsiTableIdPat then
    Exit; // not a PAT
  lSecLen := ((AData[lOff + 1] and cPsiLengthHighMask) shl 8) or AData[lOff + 2];
  lPos := lOff + cPatHeaderSize;
  while (lPos + cPatEntrySize <= lOff + cPsiSectionHeaderSize + lSecLen - cPsiCrcSize) and
    (lPos + cPatEntrySize <= ALen) do
  begin
    lProgram := (AData[lPos] shl 8) or AData[lPos + 1];
    if lProgram <> 0 then // program 0 = the network PID, not a PMT
    begin
      FPmtPid := ((AData[lPos + 2] and cTsPidHighMask) shl 8) or AData[lPos + 3];
      Exit;
    end;
    Inc(lPos, cPatEntrySize);
  end;
end;

procedure TTsAnalyzer.ParsePmt(const AData: PByte; ALen: Integer);
var
  lPointer, lOff, lSecLen, lEndPos, lPos, lInfoLen, lStreamType, lEsPid, lEsLen, lDesc, lDescTag, lDescLen: Integer;
  lLang, lCodec, lReg: string;
  lAudio: TProbeAudio;
begin
  lPointer := AData[0];
  lOff := 1 + lPointer;
  if lOff + cPmtHeaderSize > ALen then
    Exit;
  if AData[lOff] <> cPsiTableIdPmt then
    Exit; // not a PMT
  lSecLen := ((AData[lOff + 1] and cPsiLengthHighMask) shl 8) or AData[lOff + 2];
  lEndPos := Min(lOff + cPsiSectionHeaderSize + lSecLen - cPsiCrcSize, ALen); // before the CRC
  lInfoLen := ((AData[lOff + 10] and cPsiLengthHighMask) shl 8) or AData[lOff + 11];
  lPos := lOff + cPmtHeaderSize + lInfoLen;
  while lPos + cPmtEsHeaderSize <= lEndPos do
  begin
    lStreamType := AData[lPos];
    lEsPid := ((AData[lPos + 1] and cTsPidHighMask) shl 8) or AData[lPos + 2];
    lEsLen := ((AData[lPos + 3] and cPsiLengthHighMask) shl 8) or AData[lPos + 4];
    // descriptors: language, AC-3 / E-AC-3 / DTS, registration
    lLang := '';
    lCodec := '';
    lReg := '';
    lDesc := lPos + cPmtEsHeaderSize;
    while (lDesc + cDescHeaderSize <= lPos + cPmtEsHeaderSize + lEsLen) and
      (lDesc + cDescHeaderSize <= lEndPos) do
    begin
      lDescTag := AData[lDesc];
      lDescLen := AData[lDesc + 1];
      if lDesc + cDescHeaderSize + lDescLen > lEndPos then
        Break;
      case lDescTag of
        cDescIso639Language:
          if lDescLen >= cIso639CodeLen then
            lLang := Chr(AData[lDesc + 2]) + Chr(AData[lDesc + 3]) + Chr(AData[lDesc + 4]);
        cDescAc3: lCodec := cCodecAc3;
        cDescEac3: lCodec := cCodecEac3;
        cDescDts: lCodec := cCodecDts;
        cDescAac: lCodec := cCodecAac;
        cDescRegistration:
          if lDescLen >= cRegFormatIdLen then
            lReg := Chr(AData[lDesc + 2]) + Chr(AData[lDesc + 3]) + Chr(AData[lDesc + 4]) + Chr(AData[lDesc + 5]);
      end;
      Inc(lDesc, cDescHeaderSize + lDescLen);
    end;
    case lStreamType of
      cStreamTypeMpeg1Video, cStreamTypeMpeg2Video, cStreamTypeH264, cStreamTypeHevc:
        if FVideoPid = 0 then
        begin
          FVideoPid := lEsPid;
          FVideoType := lStreamType;
        end;
      cStreamTypeMpeg1Audio, cStreamTypeMpeg2Audio: lCodec := cCodecMp2;
      cStreamTypeAacAdts: lCodec := cCodecAac;
      cStreamTypeAacLatm: lCodec := cCodecAacLatm;
      cStreamTypeAc3: lCodec := cCodecAc3;
      cStreamTypeEac3: lCodec := cCodecEac3;
      cStreamTypePrivatePes:
        begin
          if (lCodec = '') and (lReg = cRegFormatAc3) then
            lCodec := cCodecAc3;
          if (lCodec = '') and (lReg = cRegFormatEac3) then
            lCodec := cCodecEac3;
          if (FVideoPid = 0) and (lReg = cRegFormatHevc) then
          begin
            FVideoPid := lEsPid;
            FVideoType := cStreamTypeHevc;
          end;
        end;
    else
      lCodec := '';
    end;
    if (lCodec <> '') and (lEsPid <> FVideoPid) then
    begin
      lAudio.Codec := lCodec;
      lAudio.Language := lLang.Trim;
      FAudio := FAudio + [lAudio];
    end;
    Inc(lPos, cPmtEsHeaderSize + lEsLen);
  end;
  FPmtDone := True;
end;

procedure TTsAnalyzer.AppendVes(const AData: PByte; ALen: Integer);
begin
  if (ALen <= 0) or (FVesLen >= cMaxVesBytes) then
    Exit;
  ALen := Min(ALen, cMaxVesBytes - FVesLen);
  if FVesLen + ALen > Length(FVes) then
    SetLength(FVes, Max(FVesLen + ALen, Length(FVes) * 2 + cVesGrowBytes));
  Move(AData^, FVes[FVesLen], ALen);
  Inc(FVesLen, ALen);
end;

procedure TTsAnalyzer.VideoPayload(const AData: PByte; ALen: Integer; AStart: Boolean);
var
  lHdrLen: Integer;
  lPts: Int64;
begin
  if not AStart then
  begin
    AppendVes(AData, ALen);
    Exit;
  end;
  // PES header: 00 00 01 sid len(2) flags(2) hdrlen
  if (ALen < cPesHeaderSize) or (AData[0] <> 0) or (AData[1] <> 0) or (AData[2] <> 1) then
    Exit;
  lHdrLen := cPesHeaderSize + AData[cPesHeaderLenOffset];
  if ((AData[cPesFlagsOffset] and cPesPtsFlag) <> 0) and (ALen >= cPesWithPtsSize) then
  begin
    // 33-bit PTS spread over 5 bytes with marker bits
    lPts := (Int64((AData[cPesPtsOffset] shr 1) and 7) shl 30) or
           (Int64(AData[cPesPtsOffset + 1]) shl 22) or
           (Int64(AData[cPesPtsOffset + 2] shr 1) shl 15) or
           (Int64(AData[cPesPtsOffset + 3]) shl 7) or Int64(AData[cPesPtsOffset + 4] shr 1);
    if FPtsCount = 0 then
    begin
      FPtsFirst := lPts;
      FPtsMin := lPts;
      FPtsMax := lPts;
      FBytesAtMin := FBytesTotal;
      FBytesAtMax := FBytesTotal;
    end
    else
    begin
      // unwrap the 33-bit clock relative to the first timestamp
      if lPts < FPtsFirst - (cPtsWrap div 2) then
        Inc(lPts, cPtsWrap);
      if lPts < FPtsMin then
      begin
        FPtsMin := lPts;
        if FPtsCount < cPtsEarlySamples then
          FBytesAtMin := FBytesTotal;
      end;
      if lPts > FPtsMax then
      begin
        FPtsMax := lPts;
        FBytesAtMax := FBytesTotal;
      end;
    end;
    Inc(FPtsCount);
  end;
  if lHdrLen < ALen then
    AppendVes(@AData[lHdrLen], ALen - lHdrLen);
end;

procedure TTsAnalyzer.Finish(var AResult: TProbeResult);
var
  i, j, lNalStart, lNalType: Integer;
  lSpan: Double;
  lNal: TBytes;
  lRate: Integer;
  lGot: Boolean;
begin
  AResult.Audio := FAudio;
  case FVideoType of
    cStreamTypeMpeg1Video: AResult.VideoCodec := cCodecMpeg1;
    cStreamTypeMpeg2Video: AResult.VideoCodec := cCodecMpeg2;
    cStreamTypeH264: AResult.VideoCodec := cCodecH264;
    cStreamTypeHevc: AResult.VideoCodec := cCodecHevc;
  end;

  // timestamps -> media duration, frame rate, bitrate
  if FPtsCount >= 2 then
  begin
    lSpan := (FPtsMax - FPtsMin) / cPtsClockHz;
    if lSpan > 0 then
    begin
      AResult.MediaSeconds := lSpan;
      AResult.Fps := RoundTo((FPtsCount - 1) / lSpan, -2);
      if FBytesAtMax > FBytesAtMin then
        AResult.BitrateKbps := Round((FBytesAtMax - FBytesAtMin) * 8 / lSpan / 1000);
    end;
  end;

  // hunt the sequence parameters in the collected elementary stream
  lGot := False;
  i := 0;
  while (not lGot) and (i + 4 < FVesLen) do
  begin
    if (FVes[i] = 0) and (FVes[i + 1] = 0) and (FVes[i + 2] = 1) then
    begin
      lNalStart := i + cStartCodeSize;
      // find the next start code (end of this NAL)
      j := lNalStart;
      while (j + 3 < FVesLen) and not ((FVes[j] = 0) and (FVes[j + 1] = 0) and
        ((FVes[j + 2] = 1) or ((FVes[j + 2] = 0) and (FVes[j + 3] = 1)))) do
        Inc(j);
      if j + 3 >= FVesLen then
        j := FVesLen;
      case FVideoType of
        cStreamTypeH264:
          begin
            lNalType := FVes[lNalStart] and cH264NalTypeMask;
            if lNalType = cH264NalSps then
            begin
              lNal := Unescape(@FVes[lNalStart], j - lNalStart);
              lGot := ParseH264Sps(lNal, AResult);
            end;
          end;
        cStreamTypeHevc:
          begin
            lNalType := (FVes[lNalStart] shr cHevcNalTypeShift) and cHevcNalTypeMask;
            if lNalType = cHevcNalSps then
            begin
              lNal := Unescape(@FVes[lNalStart], j - lNalStart);
              lGot := ParseHevcSps(lNal, AResult);
            end;
          end;
        cStreamTypeMpeg1Video, cStreamTypeMpeg2Video:
          if (FVes[lNalStart] = cMpeg2SequenceHeader) and (lNalStart + 4 < FVesLen) then
          begin
            // 12-bit width, 12-bit height, 4-bit aspect, 4-bit frame_rate_code
            AResult.Width := (FVes[lNalStart + 1] shl 4) or (FVes[lNalStart + 2] shr 4);
            AResult.Height := ((FVes[lNalStart + 2] and $0F) shl 8) or FVes[lNalStart + 3];
            lRate := FVes[lNalStart + 4] and cMpeg2FrameRateMask;
            if (AResult.Fps = 0) and (lRate in [Low(cMpeg2FrameRates)..High(cMpeg2FrameRates)]) then
              AResult.Fps := cMpeg2FrameRates[lRate];
            AResult.BitDepth := cBitDepthBase;
            // sequence_extension follows: progressive_sequence bit
            AResult.Interlaced := True;
            for j := lNalStart to Min(FVesLen - 6, lNalStart + cMpeg2ExtScanBytes) do
              if (FVes[j] = 0) and (FVes[j + 1] = 0) and (FVes[j + 2] = 1) and
                 (FVes[j + 3] = cMpeg2ExtensionStart) and
                 ((FVes[j + 4] shr 4) = cMpeg2SequenceExtId) then
              begin
                AResult.Interlaced := ((FVes[j + 5] shr 3) and 1) = 0;
                Break;
              end;
            AResult.Profile := '';
            lGot := True;
          end;
      end;
      i := lNalStart;
    end
    else
      Inc(i);
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
  FreeAndNil(FText);
  inherited;
end;

function TProbeSink.Write(const Buffer; Count: Longint): Longint;
var
  lHead: TBytes;
  lKeep, lOld: Integer;
begin
  Result := Count;
  if Count <= 0 then
    Exit;
  if FFirstMs < 0 then
  begin
    FFirstMs := FWatch.ElapsedMilliseconds;
    if FSniff then
    begin
      SetLength(lHead, Min(Count, cSniffBytes));
      Move(Buffer, lHead[0], Length(lHead));
      // skip a UTF-8 BOM / leading whitespace before #EXTM3U
      FIsPlaylist := Pos(cHlsHeader, TEncoding.ANSI.GetString(lHead)) > 0;
    end;
  end;
  if Length(FHead) < cErrorHeadBytes then
  begin
    lKeep := Min(Count, cErrorHeadBytes - Length(FHead));
    lOld := Length(FHead);
    SetLength(FHead, lOld + lKeep);
    Move(Buffer, FHead[lOld], lKeep);
  end;
  Inc(FBytes, Count);
  if FIsPlaylist then
  begin
    if FText.Size + Count > cMaxPlaylistBytes then
      raise EProbeEnough.Create('playlist too large');
    FText.WriteBuffer(Buffer, Count);
    Exit;
  end;
  FAnalyzer.Feed(Buffer, Count);
  if (FWatch.ElapsedMilliseconds >= FMaxMs) or (FBytes >= cMaxProbeBytes) then
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
  lUri: TIdURI;
begin
  if ContainsText(ARef, cSchemeSeparator) then
    Exit(ARef);
  lUri := TIdURI.Create(ABase);
  try
    if ARef.StartsWith('/') then
      Result := lUri.Protocol + cSchemeSeparator + lUri.Host + IfThen(lUri.Port <> '', ':' + lUri.Port, '') + ARef
    else
      Result := lUri.Protocol + cSchemeSeparator + lUri.Host + IfThen(lUri.Port <> '', ':' + lUri.Port, '') +
        lUri.Path + ARef;
  finally
    FreeAndNil(lUri);
  end;
end;

type
  TRedirectCounter = class
    Count: Integer;
    LastUrl: string; // the URL actually served (after the provider's redirects)
    UserAgent: string; // per-source UA ('' = cProbeUserAgent)
    Referer: string;
    procedure OnRedirect(ASender: TObject; var ADest: string; var ANumRedirect: Integer;
      var AHandled: Boolean; var AMethod: string);
  end;

procedure TRedirectCounter.OnRedirect(ASender: TObject; var ADest: string;
  var ANumRedirect: Integer; var AHandled: Boolean; var AMethod: string);
begin
  Inc(Count);
  if ContainsText(ADest, cSchemeSeparator) then
    LastUrl := ADest
  else if LastUrl <> '' then
    LastUrl := ResolveUrl(LastUrl, ADest);
end;

function NewProbeHttp(ARedir: TRedirectCounter): TIdHTTP;
var
  lSsl: TIdSSLIOHandlerSocketOpenSSL;
begin
  Result := TIdHTTP.Create(nil);
  // look like VLC on the wire, not just in the User-Agent: some panels reject
  // anything else (seen: ProviderB answers HTTP 461 to Indy's default headers)
  Result.Request.UserAgent := cProbeUserAgent;
  if (ARedir <> nil) and (ARedir.UserAgent.Trim <> '') then
    Result.Request.UserAgent := ARedir.UserAgent.Trim;
  if (ARedir <> nil) and (ARedir.Referer.Trim <> '') then
    Result.Request.Referer := ARedir.Referer.Trim;
  Result.Request.Accept := cAcceptAny;
  Result.Request.AcceptLanguage := cAcceptLanguage;
  Result.Request.Connection := cConnectionClose;
  Result.Request.CustomHeaders.AddValue(cHeaderRange, cRangeFromStart);
  Result.Request.CustomHeaders.AddValue(cHeaderIcyMetaData, cIcyMetaDataOn);
  Result.HandleRedirects := True;
  Result.RedirectMaximum := cMaxRedirects;
  Result.ConnectTimeout := cTimeoutConnectMs;
  Result.ReadTimeout := cTimeoutReadMs;
  Result.HTTPOptions := Result.HTTPOptions + [hoNoProtocolErrorException];
  if ARedir <> nil then
    Result.OnRedirect := ARedir.OnRedirect;
  // TLS handler always attached: plain-http portals often redirect to https nodes
  lSsl := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
  lSsl.SSLOptions.SSLVersions := [sslvTLSv1_2];
  Result.IOHandler := lSsl;
end;

/// GET AUrl into ASink. Returns the HTTP status (0 = no response); AError holds
/// a transport failure (an EProbeEnough stop is a success). AServer = Server header.
function FetchIntoEx(const AUrl: string; ASink: TProbeSink; ARedir: TRedirectCounter;
  out AFinalUrl, AContentType, AError, AServer: string): Integer;
var
  lHttp: TIdHTTP;
begin
  AError := '';
  AFinalUrl := AUrl;
  AContentType := '';
  ARedir.LastUrl := AUrl;
  lHttp := NewProbeHttp(ARedir);
  try
    try
      lHttp.Get(AUrl, ASink);
      Result := lHttp.ResponseCode;
    except
      on EProbeEnough do
        Result := lHttp.ResponseCode;
      on E: Exception do
      begin
        Result := lHttp.ResponseCode;
        AError := E.Message;
      end;
    end;
    AContentType := lHttp.Response.ContentType;
    AServer := lHttp.Response.Server;
    if ARedir.LastUrl <> '' then
      AFinalUrl := ARedir.LastUrl;
  finally
    FreeAndNil(lHttp);
  end;
end;

/// GET AUrl into ASink. Returns the HTTP status; ERROR text on transport failure
/// (an EProbeEnough stop is a success).
function FetchInto(const AUrl: string; ASink: TProbeSink; ARedir: TRedirectCounter;
  out AFinalUrl, AContentType, AError: string): Integer;
var
  lServer: string;
begin
  Result := FetchIntoEx(AUrl, ASink, ARedir, AFinalUrl, AContentType, AError, lServer);
end;

function IsHttpSuccess(ACode: Integer): Boolean;
begin
  Result := (ACode = cHttpStatusOk) or (ACode = cHttpStatusPartialContent);
end;

function IsRefusalStatus(ACode: Integer): Boolean;
var
  lStatus: Integer;
begin
  Result := False;
  for lStatus in cRefusalStatuses do
    if ACode = lStatus then
      Exit(True);
end;

function AttrValue(const ALine, AName: string): string;
var
  lPos, lEnd: Integer;
begin
  Result := '';
  lPos := Pos(AName + '=', UpperCase(ALine));
  if lPos = 0 then
    Exit;
  Inc(lPos, Length(AName) + 1);
  if (lPos <= Length(ALine)) and (ALine[lPos] = '"') then
  begin
    lEnd := PosEx('"', ALine, lPos + 1);
    if lEnd = 0 then
      lEnd := Length(ALine) + 1;
    Result := Copy(ALine, lPos + 1, lEnd - lPos - 1);
  end
  else
  begin
    lEnd := PosEx(',', ALine, lPos);
    if lEnd = 0 then
      lEnd := Length(ALine) + 1;
    Result := Copy(ALine, lPos, lEnd - lPos);
  end;
end;

procedure ApplyHlsCodecs(const ACodecs, AResolution: string; var AResult: TProbeResult);
var
  lCodec: string;
  lAudio: TProbeAudio;
  lPosX: Integer;
begin
  for lCodec in ACodecs.Split([',']) do
  begin
    if StartsText(cHlsCodecAvc1, lCodec.Trim) and (AResult.VideoCodec = '') then
      AResult.VideoCodec := cCodecH264;
    if (StartsText(cHlsCodecHvc1, lCodec.Trim) or StartsText(cHlsCodecHev1, lCodec.Trim)) and
      (AResult.VideoCodec = '') then
      AResult.VideoCodec := cCodecHevc;
    if (Length(AResult.Audio) = 0) then
    begin
      lAudio.Language := '';
      lAudio.Codec := '';
      if StartsText(cHlsCodecMp4a, lCodec.Trim) then
        lAudio.Codec := cCodecAac;
      if StartsText(cHlsCodecAc3, lCodec.Trim) then
        lAudio.Codec := cCodecAc3;
      if StartsText(cHlsCodecEc3, lCodec.Trim) then
        lAudio.Codec := cCodecEac3;
      if lAudio.Codec <> '' then
        AResult.Audio := [lAudio];
    end;
  end;
  lPosX := Pos('X', UpperCase(AResolution));
  if (AResult.Width = 0) and (lPosX > 0) then
  begin
    AResult.Width := StrToIntDef(Copy(AResolution, 1, lPosX - 1), 0);
    AResult.Height := StrToIntDef(Copy(AResolution, lPosX + 1, MaxInt), 0);
  end;
end;

procedure ProbeHls(const APlaylist, ABaseUrl: string; AAnalyzer: TTsAnalyzer;
  ARedir: TRedirectCounter; AWatch: TStopwatch; AMaxMs: Int64; var AResult: TProbeResult);
var
  lLines, lSegs: TArray<string>;
  lLine, lUrl, lText, lFinalUrl, lContentType, lErr, lCodecs, lResolution: string;
  i, lBest, lBandwidth, lCode, k, lStart: Integer;
  lSink: TProbeSink;
  lFmp4: Boolean;
  lWall: TStopwatch;
begin
  AResult.Container := cContainerHls;
  lCodecs := '';
  lResolution := '';
  lText := APlaylist;
  lUrl := ABaseUrl;
  // master playlist -> the highest-bandwidth variant
  if ContainsText(lText, cHlsTagStreamInf) then
  begin
    lLines := lText.Split([#10]);
    lBest := -1;
    lUrl := '';
    for i := 0 to High(lLines) do
    begin
      lLine := lLines[i].Trim;
      if StartsText(cHlsTagStreamInf, lLine) then
      begin
        lBandwidth := StrToIntDef(AttrValue(lLine, cHlsAttrBandwidth), 0);
        if (lBandwidth > lBest) and (i < High(lLines)) then
        begin
          lBest := lBandwidth;
          lCodecs := AttrValue(lLine, cHlsAttrCodecs);
          lResolution := AttrValue(lLine, cHlsAttrResolution);
          k := i + 1;
          while (k <= High(lLines)) and ((lLines[k].Trim = '') or lLines[k].Trim.StartsWith('#')) do
            Inc(k);
          if k <= High(lLines) then
            lUrl := ResolveUrl(ABaseUrl, lLines[k].Trim);
        end;
      end;
    end;
    ApplyHlsCodecs(lCodecs, lResolution, AResult);
    if lUrl = '' then
    begin
      AResult.Error := 'HLS master playlist without variants';
      Exit;
    end;
    lSink := TProbeSink.Create(AAnalyzer, cHlsVariantBudgetMs, cSniffPlaylist);
    try
      lCode := FetchInto(lUrl, lSink, ARedir, lFinalUrl, lContentType, lErr);
      if (not IsHttpSuccess(lCode)) or not lSink.FIsPlaylist then
      begin
        AResult.Error := IfThen(lErr <> '', lErr, Format('HLS variant playlist: HTTP %d', [lCode]));
        Exit;
      end;
      lText := lSink.PlaylistText;
      lUrl := lFinalUrl;
    finally
      FreeAndNil(lSink);
    end;
  end;

  // media playlist: segment URIs; take the newest few (live edge)
  lFmp4 := ContainsText(lText, cHlsTagMap);
  lSegs := [];
  for lLine in lText.Split([#10]) do
    if (lLine.Trim <> '') and not lLine.Trim.StartsWith('#') then
      lSegs := lSegs + [ResolveUrl(lUrl, lLine.Trim)];
  if Length(lSegs) = 0 then
  begin
    AResult.Error := 'HLS playlist without segments';
    Exit;
  end;
  if lFmp4 then
  begin
    AResult.Container := cContainerHlsFmp4;
    AResult.Ok := AResult.VideoCodec <> '';
    if not AResult.Ok then
      AResult.Error := 'fMP4 HLS: only the playlist could be read';
    Exit;
  end;
  lStart := Max(0, Length(lSegs) - cHlsLiveEdgeSegments);
  lWall := TStopwatch.StartNew;
  for i := lStart to High(lSegs) do
  begin
    if AWatch.ElapsedMilliseconds >= AMaxMs then
      Break;
    AAnalyzer.ResetSync;
    lSink := TProbeSink.Create(AAnalyzer, cHlsSegmentBudgetMs, cNoSniff);
    try
      lCode := FetchInto(lSegs[i], lSink, ARedir, lFinalUrl, lContentType, lErr);
      Inc(AResult.Bytes, lSink.FBytes);
      if not IsHttpSuccess(lCode) then
      begin
        AResult.Error := IfThen(lErr <> '', lErr, Format('HLS segment: HTTP %d', [lCode]));
        Break;
      end;
    finally
      FreeAndNil(lSink);
    end;
  end;
  AResult.WallSeconds := lWall.ElapsedMilliseconds / 1000;
end;

/// 'HTTP 461 (server nginx): <the provider's own text>' — tags stripped,
/// whitespace collapsed, at most 200 chars; credentials never appear in a body.
function HttpErrorText(ACode: Integer; const AServer: string; const ABody: TBytes): string;
var
  lText: string;
  lChar: Char;
  lInTag: Boolean;
  lBuilder: TStringBuilder;
begin
  Result := Format('HTTP %d', [ACode]);
  if AServer.Trim <> '' then
    Result := Result + ' (' + AServer.Trim + ')';
  if Length(ABody) = 0 then
    Exit;
  lText := TEncoding.UTF8.GetString(ABody);
  lBuilder := TStringBuilder.Create;
  try
    lInTag := False;
    for lChar in lText do
      if lChar = '<' then
        lInTag := True
      else if lChar = '>' then
      begin
        lInTag := False;
        lBuilder.Append(' ');
      end
      else if not lInTag then
        if Ord(lChar) <= 32 then // control chars / whitespace
          lBuilder.Append(' ')
        else
          lBuilder.Append(lChar);
    lText := lBuilder.ToString;
  finally
    FreeAndNil(lBuilder);
  end;
  while Pos('  ', lText) > 0 do
    lText := StringReplace(lText, '  ', ' ', [rfReplaceAll]);
  lText := lText.Trim;
  if Length(lText) > cErrorTextMaxLen then
    lText := Copy(lText, 1, cErrorTextMaxLen) + '...';
  if lText <> '' then
    Result := Result + ': ' + lText;
end;

function ProbeStream(const AUrl: string; AMaxSeconds: Integer;
  const AUserAgent, AReferer: string): TProbeResult;
var
  lAnalyzer: TTsAnalyzer;
  lSink: TProbeSink;
  lRedir: TRedirectCounter;
  lWatch: TStopwatch;
  lCode: Integer;
  lFinalUrl, lContentType, lErr, lServer: string;
  lMaxMs: Int64;
begin
  Result := Default(TProbeResult);
  if AUrl.Trim = '' then
  begin
    Result.Error := 'no stream URL';
    Exit;
  end;
  lMaxMs := EnsureRange(AMaxSeconds, cProbeMinSeconds, cProbeMaxSeconds) * 1000;
  GProbeLock.Acquire;
  try
    lAnalyzer := nil;
    lRedir := nil;
    try
      lAnalyzer := TTsAnalyzer.Create;
      lRedir := TRedirectCounter.Create;
      lRedir.UserAgent := AUserAgent;
      lRedir.Referer := AReferer;
      try
        lWatch := TStopwatch.StartNew;
        lSink := TProbeSink.Create(lAnalyzer, lMaxMs, cSniffPlaylist);
        try
          lCode := FetchIntoEx(AUrl, lSink, lRedir, lFinalUrl, lContentType, lErr, lServer);
          // a refusal (connection limit / anti-flood: 429, 458, 461, 503, ...) is
          // often transient right after another connection closed: retry once
          if IsRefusalStatus(lCode) then
          begin
            FreeAndNil(lSink);
            FreeAndNil(lAnalyzer);
            lAnalyzer := TTsAnalyzer.Create;
            Sleep(cRefusalRetryDelayMs);
            lRedir.Count := 0;
            lWatch := TStopwatch.StartNew;
            lSink := TProbeSink.Create(lAnalyzer, lMaxMs, cSniffPlaylist);
            lCode := FetchIntoEx(AUrl, lSink, lRedir, lFinalUrl, lContentType, lErr, lServer);
          end;
          Result.FirstByteMs := Max(0, Integer(lSink.FFirstMs));
          Result.Bytes := lSink.FBytes;
          if lSink.FFirstMs >= 0 then
            Result.WallSeconds := (lWatch.ElapsedMilliseconds - lSink.FFirstMs) / 1000;
          if (lCode >= cHttpStatusErrorMin) or ((lCode = 0) and (lSink.FBytes = 0)) then
          begin
            if lCode >= cHttpStatusErrorMin then
              Result.Error := HttpErrorText(lCode, lServer, lSink.FHead)
            else
              Result.Error := IfThen(lErr <> '', lErr, 'no response');
            Exit;
          end;
          if lSink.FIsPlaylist then
            ProbeHls(lSink.PlaylistText, lFinalUrl, lAnalyzer, lRedir, lWatch, lMaxMs, Result)
          else
          begin
            Result.Container := cContainerMpegTs;
            if (lErr <> '') and (lAnalyzer.BytesTotal > 0) then
              Result.Error := 'stalled: ' + lErr  // got data, then the server stopped
            else if lErr <> '' then
              Result.Error := lErr
            else if (not lSink.FLimitHit) and (lAnalyzer.BytesTotal > 0) then
              Result.Error := 'stream ended early';
            if (lAnalyzer.BytesTotal = 0) and (lSink.FBytes > 0) then
            begin
              Result.Container := IfThen(lContentType <> '', lContentType, 'unknown');
              Result.Error := 'not an MPEG-TS stream (' + Result.Container + ')';
              Exit;
            end;
          end;
        finally
          FreeAndNil(lSink);
        end;
        if Result.Container <> cContainerHlsFmp4 then
        begin
          lAnalyzer.Finish(Result);
          if Result.Container = cContainerHls then
            Result.Bytes := lAnalyzer.BytesTotal;
          Result.Ok := (Result.VideoCodec <> '') or (Length(Result.Audio) > 0);
          if (not Result.Ok) and (Result.Error = '') then
            Result.Error := 'no video found in the stream';
        end;
        Result.Redirects := lRedir.Count;
      except
        on E: Exception do
        begin
          Result.Ok := False;
          Result.Error := E.Message;
        end;
      end;
    finally
      FreeAndNil(lRedir);
      FreeAndNil(lAnalyzer);
    end;
  finally
    GProbeLock.Release;
  end;
end;

initialization
  GProbeLock := TCriticalSection.Create;

finalization
  FreeAndNil(GProbeLock);

end.
