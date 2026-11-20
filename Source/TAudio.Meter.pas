unit TAudio.Meter;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}

{
  Level and loudness metering for interleaved Float32 audio.

  Peak and RMS are per channel over the last WindowMs (default 300 ms). Loudness
  follows ITU-R BS.1770-4 / EBU R128: K-weighting (shelf plus high-pass, computed
  for the sample rate), 100 ms sub-blocks, momentary over 400 ms, short-term over
  3 s, and integrated loudness with the absolute (-70 LUFS) and relative (-10 LU)
  gates over 400 ms blocks with 75 % overlap. All channels weigh 1.0 (mono and
  stereo; surround weights are not applied). Silence reads as NegInfinity.

  Not thread-safe; a meter belongs to the thread that feeds it. Read the values
  from another thread only through a copy made under the caller's lock.
}

interface

uses
  Math;

type
  TAudioBiquad = record
    B0, B1, B2, A1, A2: Double;
  end;

  TAudioMeter = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FSubBlockFrames: Integer;
    FWindowBlocks: Integer;
    // K-weighting state per channel: two biquads, direct form I.
    FShelf, FHighPass: TAudioBiquad;
    FX1, FX2, FY1, FY2, FZ1, FZ2: array of Double;
    // Current sub-block accumulators.
    FBlockFill: Integer;
    FBlockSquare: array of Double;     // unweighted, per channel
    FBlockPeak: array of Double;       // per channel
    FBlockWeighted: Double;            // K-weighted, summed over channels
    // Ring of finished sub-blocks (newest at FRingHead - 1).
    FRingCount, FRingHead: Integer;
    FRingWeighted: array of Double;
    FRingSquare: array of array of Double;
    FRingPeak: array of array of Double;
    // Integrated loudness: mean square of every 400 ms block above the absolute gate.
    FGatedBlocks: array of Double;
    FGatedCount: Integer;
    FClipped: Int64;
    FFrames: Int64;
    procedure FinishSubBlock;
    function RingSum(ABlocks: Integer): Double;
    function GetPeak(AChannel: Integer): Double;
    function GetPeakDb(AChannel: Integer): Double;
    function GetRmsDb(AChannel: Integer): Double;
    function GetMomentary: Double;
    function GetShortTerm: Double;
    function GetIntegrated: Double;
  public
    constructor Create(ASampleRate, AChannels: Integer; AWindowMs: Integer = 300);
    procedure Reset;
    procedure Process(AData: PSingle; AFrames: Integer);
    property Channels: Integer read FChannels;
    property SampleRate: Integer read FSampleRate;
    // Sample peak over the window, linear and in dBFS.
    property Peak[AChannel: Integer]: Double read GetPeak;
    property PeakDb[AChannel: Integer]: Double read GetPeakDb;
    // Unweighted RMS over the window in dBFS (a full-scale sine reads -3.01).
    property RmsDb[AChannel: Integer]: Double read GetRmsDb;
    // LUFS.
    property Momentary: Double read GetMomentary;
    property ShortTerm: Double read GetShortTerm;
    property Integrated: Double read GetIntegrated;
    // Samples with |x| >= 1.0 since Reset (they clip once converted to integer PCM).
    property ClippedSamples: Int64 read FClipped;
    property FramesProcessed: Int64 read FFrames;
    // The K-weighting stages for this sample rate (exposed for tests).
    property KShelf: TAudioBiquad read FShelf;
    property KHighPass: TAudioBiquad read FHighPass;
  end;

function AudioLinearToDb(AValue: Double): Double;
function AudioDbToLinear(ADb: Double): Double;

implementation

const
  SUB_BLOCK_MS = 100;
  MOMENTARY_BLOCKS = 4;    // 400 ms
  SHORT_TERM_BLOCKS = 30;  // 3 s
  ABSOLUTE_GATE = -70.0;
  RELATIVE_GATE = -10.0;
  LOUDNESS_OFFSET = -0.691;

function AudioLinearToDb(AValue: Double): Double;
begin
  if AValue <= 0 then
    Result:=NegInfinity
  else
    Result:=20 * Log10(AValue);
end;

function AudioDbToLinear(ADb: Double): Double;
begin
  if IsInfinite(ADb) AND (ADb < 0) then
    Result:=0
  else
    Result:=Power(10, ADb / 20);
end;

function EnergyToLufs(AMeanSquare: Double): Double;
begin
  if AMeanSquare <= 0 then
    Result:=NegInfinity
  else
    Result:=LOUDNESS_OFFSET + 10 * Log10(AMeanSquare);
end;

// BS.1770 K-weighting from its analog prototype, so any sample rate gets the
// filter the standard's 48 kHz coefficients were derived from.
procedure KWeighting(ASampleRate: Integer; out AShelf, AHighPass: TAudioBiquad);
var
  F0, G, Q, K, Vh, Vb, A0: Double;
begin
  F0:=1681.974450955533;
  G:=3.999843853973347;
  Q:=0.7071752369554196;
  K:=Tan(Pi * F0 / ASampleRate);
  Vh:=Power(10, G / 20);
  Vb:=Power(Vh, 0.4996667741545416);
  A0:=1 + K / Q + K * K;
  AShelf.B0:=(Vh + Vb * K / Q + K * K) / A0;
  AShelf.B1:=2 * (K * K - Vh) / A0;
  AShelf.B2:=(Vh - Vb * K / Q + K * K) / A0;
  AShelf.A1:=2 * (K * K - 1) / A0;
  AShelf.A2:=(1 - K / Q + K * K) / A0;

  F0:=38.13547087602444;
  Q:=0.5003270373238773;
  K:=Tan(Pi * F0 / ASampleRate);
  A0:=1 + K / Q + K * K;
  AHighPass.B0:=1;
  AHighPass.B1:=-2;
  AHighPass.B2:=1;
  AHighPass.A1:=2 * (K * K - 1) / A0;
  AHighPass.A2:=(1 - K / Q + K * K) / A0;
end;

{ TAudioMeter }

constructor TAudioMeter.Create(ASampleRate, AChannels, AWindowMs: Integer);
var
  I: Integer;
begin
  inherited Create;
  if (ASampleRate <= 0) OR (AChannels <= 0) then
    raise EInvalidArgument.Create('TAudioMeter needs a positive sample rate and channel count');
  FSampleRate:=ASampleRate;
  FChannels:=AChannels;
  FSubBlockFrames:=ASampleRate * SUB_BLOCK_MS DIV 1000;
  FWindowBlocks:=Max(1, (AWindowMs + SUB_BLOCK_MS DIV 2) DIV SUB_BLOCK_MS);
  KWeighting(ASampleRate, FShelf, FHighPass);
  SetLength(FX1, AChannels);
  SetLength(FX2, AChannels);
  SetLength(FY1, AChannels);
  SetLength(FY2, AChannels);
  SetLength(FZ1, AChannels);
  SetLength(FZ2, AChannels);
  SetLength(FBlockSquare, AChannels);
  SetLength(FBlockPeak, AChannels);
  SetLength(FRingWeighted, Max(SHORT_TERM_BLOCKS, FWindowBlocks));
  SetLength(FRingSquare, Length(FRingWeighted));
  SetLength(FRingPeak, Length(FRingWeighted));
  for I:=0 to High(FRingSquare) do
  begin
    SetLength(FRingSquare[I], AChannels);
    SetLength(FRingPeak[I], AChannels);
  end;
  Reset;
end;

procedure TAudioMeter.Reset;
var
  C, I: Integer;
begin
  for C:=0 to FChannels - 1 do
  begin
    FX1[C]:=0; FX2[C]:=0; FY1[C]:=0; FY2[C]:=0; FZ1[C]:=0; FZ2[C]:=0;
    FBlockSquare[C]:=0;
    FBlockPeak[C]:=0;
  end;
  for I:=0 to High(FRingWeighted) do
  begin
    FRingWeighted[I]:=0;
    for C:=0 to FChannels - 1 do
    begin
      FRingSquare[I][C]:=0;
      FRingPeak[I][C]:=0;
    end;
  end;
  FBlockFill:=0;
  FBlockWeighted:=0;
  FRingCount:=0;
  FRingHead:=0;
  FGatedBlocks:=nil;
  FGatedCount:=0;
  FClipped:=0;
  FFrames:=0;
end;

procedure TAudioMeter.Process(AData: PSingle; AFrames: Integer);
var
  F, C: Integer;
  X, Y, Z: Double;
  P: PSingle;
begin
  P:=AData;
  for F:=0 to AFrames - 1 do
  begin
    for C:=0 to FChannels - 1 do
    begin
      X:=P^;
      Inc(P);
      if Abs(X) >= 1 then
        Inc(FClipped);
      if Abs(X) > FBlockPeak[C] then
        FBlockPeak[C]:=Abs(X);
      FBlockSquare[C]:=FBlockSquare[C] + X * X;
      // Shelf, then high-pass.
      Y:=FShelf.B0 * X + FShelf.B1 * FX1[C] + FShelf.B2 * FX2[C] - FShelf.A1 * FY1[C] - FShelf.A2 * FY2[C];
      FX2[C]:=FX1[C];
      FX1[C]:=X;
      Z:=FHighPass.B0 * Y + FHighPass.B1 * FY1[C] + FHighPass.B2 * FY2[C] - FHighPass.A1 * FZ1[C] - FHighPass.A2 * FZ2[C];
      FY2[C]:=FY1[C];
      FY1[C]:=Y;
      FZ2[C]:=FZ1[C];
      FZ1[C]:=Z;
      FBlockWeighted:=FBlockWeighted + Z * Z;
    end;
    Inc(FBlockFill);
    if FBlockFill = FSubBlockFrames then
      FinishSubBlock;
  end;
  Inc(FFrames, AFrames);
end;

procedure TAudioMeter.FinishSubBlock;
var
  C: Integer;
  Block: Double;
begin
  FRingWeighted[FRingHead]:=FBlockWeighted / FSubBlockFrames;
  for C:=0 to FChannels - 1 do
  begin
    FRingSquare[FRingHead][C]:=FBlockSquare[C] / FSubBlockFrames;
    FRingPeak[FRingHead][C]:=FBlockPeak[C];
    FBlockSquare[C]:=0;
    FBlockPeak[C]:=0;
  end;
  FBlockWeighted:=0;
  FBlockFill:=0;
  FRingHead:=(FRingHead + 1) MOD Length(FRingWeighted);
  if FRingCount < Length(FRingWeighted) then
    Inc(FRingCount);
  // Every 100 ms a new 400 ms gating block ends (75 % overlap).
  if FRingCount >= MOMENTARY_BLOCKS then
  begin
    Block:=RingSum(MOMENTARY_BLOCKS) / MOMENTARY_BLOCKS;
    if EnergyToLufs(Block) > ABSOLUTE_GATE then
    begin
      if FGatedCount = Length(FGatedBlocks) then
        SetLength(FGatedBlocks, Max(1024, 2 * Length(FGatedBlocks)));
      FGatedBlocks[FGatedCount]:=Block;
      Inc(FGatedCount);
    end;
  end;
end;

function TAudioMeter.RingSum(ABlocks: Integer): Double;
var
  I, Index: Integer;
begin
  Result:=0;
  for I:=1 to Min(ABlocks, FRingCount) do
  begin
    Index:=(FRingHead - I + Length(FRingWeighted)) MOD Length(FRingWeighted);
    Result:=Result + FRingWeighted[Index];
  end;
end;

function TAudioMeter.GetPeak(AChannel: Integer): Double;
var
  I, Index: Integer;
begin
  Result:=FBlockPeak[AChannel];
  for I:=1 to Min(FWindowBlocks, FRingCount) do
  begin
    Index:=(FRingHead - I + Length(FRingWeighted)) MOD Length(FRingWeighted);
    Result:=Max(Result, FRingPeak[Index][AChannel]);
  end;
end;

function TAudioMeter.GetPeakDb(AChannel: Integer): Double;
begin
  Result:=AudioLinearToDb(GetPeak(AChannel));
end;

function TAudioMeter.GetRmsDb(AChannel: Integer): Double;
var
  I, Index, N: Integer;
  Sum: Double;
begin
  Sum:=0;
  N:=Min(FWindowBlocks, FRingCount);
  for I:=1 to N do
  begin
    Index:=(FRingHead - I + Length(FRingWeighted)) MOD Length(FRingWeighted);
    Sum:=Sum + FRingSquare[Index][AChannel];
  end;
  if (N = 0) OR (Sum <= 0) then
    Result:=NegInfinity
  else
    Result:=10 * Log10(Sum / N);
end;

function TAudioMeter.GetMomentary: Double;
begin
  if FRingCount < MOMENTARY_BLOCKS then
    Result:=NegInfinity
  else
    Result:=EnergyToLufs(RingSum(MOMENTARY_BLOCKS) / MOMENTARY_BLOCKS);
end;

function TAudioMeter.GetShortTerm: Double;
var
  N: Integer;
begin
  N:=Min(SHORT_TERM_BLOCKS, FRingCount);
  if N < SHORT_TERM_BLOCKS then
    Result:=NegInfinity
  else
    Result:=EnergyToLufs(RingSum(N) / N);
end;

function TAudioMeter.GetIntegrated: Double;
var
  I, N: Integer;
  Sum, Threshold: Double;
begin
  Result:=NegInfinity;
  if FGatedCount = 0 then
    Exit;
  Sum:=0;
  for I:=0 to FGatedCount - 1 do
    Sum:=Sum + FGatedBlocks[I];
  Threshold:=EnergyToLufs(Sum / FGatedCount) + RELATIVE_GATE;
  Sum:=0;
  N:=0;
  for I:=0 to FGatedCount - 1 do
    if EnergyToLufs(FGatedBlocks[I]) > Threshold then
    begin
      Sum:=Sum + FGatedBlocks[I];
      Inc(N);
    end;
  if N > 0 then
    Result:=EnergyToLufs(Sum / N);
end;

end.
