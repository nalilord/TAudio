unit TAudio.Dynamics;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}

{
  Dynamics processors for interleaved Float32 audio: gain, compressor (with an
  optional sidechain) and a look-ahead true-peak limiter.

  All derive from TAudioFilter and process a block in place. They work on their
  own or in a TAudioMixer input's filter chain (TAudioMixerInput.AddFilter),
  where the mixer feeds sidechains and compensates latency.

  Parameters may be set from any thread; they are read once per block.

  TAudioGainFilter   GainDb, ramped over one block.
  TAudioCompressor   Feed-forward, stereo-linked. Detector: the larger absolute
                     sample of all channels (of the sidechain when one is
                     given), smoothed by one-pole attack/release on the linear
                     level. Gain computer in dB with an optional soft knee:
                       over = level - threshold
                       reduction = over * (1 - 1/ratio)   (hard knee, over > 0)
                     then makeup gain. No latency.
  TAudioLimiter      Look-ahead brick wall at CeilingDb. Detector: 4x
                     oversampled true peak (polyphase windowed sinc) when
                     TruePeak, else sample peak. The target gain per sample is
                     min(1, ceiling / peak); a sliding minimum over the
                     look-ahead window followed by a moving average of the same
                     length makes the gain reach the target exactly when the
                     peak leaves the delay line, so no sample exceeds the
                     ceiling and the gain never steps. Release is a one-pole
                     return toward unity. Latency = look-ahead window - 1 plus
                     the oversampler's delay, reported by Latency.
}

interface

uses
  SysUtils;

type
  TAudioFilter = class
  private
    FName: string;
    FEnabled: Boolean;
  protected
    FSampleRate: Integer;
    FChannels: Integer;
    procedure DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle); virtual; abstract;
  public
    constructor Create(const AName: string = '');
    // Called before the first block and whenever the format changes; resets state.
    procedure Prepare(ASampleRate, AChannels: Integer); virtual;
    procedure Reset; virtual;
    // In place, AFrames * Channels samples. ASidechain: same layout, or nil.
    procedure Process(AData: PSingle; AFrames: Integer; ASidechain: PSingle = nil);
    // Delay the filter adds, in frames.
    function Latency: Integer; virtual;
    property Name: string read FName write FName;
    // A disabled filter passes audio unchanged and adds no latency.
    property Enabled: Boolean read FEnabled write FEnabled;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
  end;

  TAudioGainFilter = class(TAudioFilter)
  private
    FGainDb: Double;
    FApplied: Double;
  protected
    procedure DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle); override;
  public
    constructor Create(const AName: string = '');
    procedure Reset; override;
    property GainDb: Double read FGainDb write FGainDb;
  end;

  TAudioCompressor = class(TAudioFilter)
  private
    FThresholdDb: Double;
    FRatio: Double;
    FAttackMs: Double;
    FReleaseMs: Double;
    FMakeupDb: Double;
    FKneeDb: Double;
    FEnvelope: Double;
    FReductionDb: Double;
    FMaxReductionDb: Double;
    function ComputeReductionDb(ALevelDb: Double): Double;
  protected
    procedure DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle); override;
  public
    constructor Create(const AName: string = '');
    procedure Reset; override;
    // Static curve: output level in dB for a steady input (or sidechain) level, before makeup.
    function StaticReductionDb(ALevelDb: Double): Double;
    property ThresholdDb: Double read FThresholdDb write FThresholdDb;
    // >= 1; 1 = no compression.
    property Ratio: Double read FRatio write FRatio;
    property AttackMs: Double read FAttackMs write FAttackMs;
    property ReleaseMs: Double read FReleaseMs write FReleaseMs;
    property MakeupDb: Double read FMakeupDb write FMakeupDb;
    // Width of the soft knee in dB; 0 = hard knee.
    property KneeDb: Double read FKneeDb write FKneeDb;
    // Gain reduction at the end of the last block (<= 0 dB) and the deepest since ResetMeter.
    property ReductionDb: Double read FReductionDb;
    property MaxReductionDb: Double read FMaxReductionDb;
    procedure ResetMeter;
  end;

  TAudioLimiter = class(TAudioFilter)
  private
    FCeilingDb: Double;
    FReleaseMs: Double;
    FLookaheadMs: Double;
    FTruePeak: Boolean;
    // Configuration the state was built for.
    FWindow: Integer;
    FPeakDelay: Integer;
    FBuiltTruePeak: Boolean;
    // Audio delay line (interleaved), FDelay frames.
    FDelay: Integer;
    FLine: TArray<Single>;
    FLinePos: Integer;
    // Detector history (interleaved), stored twice in a row (2 * TP_TAPS frames) so the
    // oversampler always reads TP_TAPS contiguous frames without wrapping.
    FHistory: TArray<Double>;
    FHistoryPos: Integer;
    // Sliding minimum of the target gain (monotonic deque of (index, value)).
    FMinIndex: TArray<Int64>;
    FMinValue: TArray<Double>;
    FMinHead, FMinCount: Integer;
    // Moving average of the sliding minimum.
    FAvgRing: TArray<Double>;
    FAvgPos: Integer;
    FAvgSum: Double;
    FAvgCount: Integer;
    FSample: Int64;
    FGain: Double;
    FReductionDb: Double;
    FMaxReductionDb: Double;
    function WindowFrames: Integer;
    function NeedsBuild: Boolean;
    procedure Build;
  protected
    procedure DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle); override;
  public
    constructor Create(const AName: string = '');
    procedure Prepare(ASampleRate, AChannels: Integer); override;
    procedure Reset; override;
    function Latency: Integer; override;
    procedure ResetMeter;
    property CeilingDb: Double read FCeilingDb write FCeilingDb;
    property ReleaseMs: Double read FReleaseMs write FReleaseMs;
    // Changing it (or TruePeak) rebuilds the state at the next block: a short glitch.
    property LookaheadMs: Double read FLookaheadMs write FLookaheadMs;
    property TruePeak: Boolean read FTruePeak write FTruePeak;
    property ReductionDb: Double read FReductionDb;
    property MaxReductionDb: Double read FMaxReductionDb;
  end;

function AudioTruePeakFilterTaps: Integer;

implementation

uses
  Math;

const
  // 4x oversampler: 4 phases of TP_TAPS taps (Kaiser-windowed sinc, cut-off at the input Nyquist).
  TP_PHASES = 4;
  TP_TAPS = 12;

var
  TruePeakCoef: array[0..TP_PHASES - 1, 0..TP_TAPS - 1] of Double;

function AudioTruePeakFilterTaps: Integer;
begin
  Result:=TP_TAPS;
end;

function BesselI0(X: Double): Double;
var
  Sum, Term: Double;
  K: Integer;
begin
  Sum:=1;
  Term:=1;
  for K:=1 to 50 do
  begin
    Term:=Term * Sqr(X / (2 * K));
    Sum:=Sum + Term;
    if Term < 1E-12 * Sum then
      Break;
  end;
  Result:=Sum;
end;

procedure BuildTruePeakCoefficients;
const
  Beta = 6.0;
var
  P, K: Integer;
  T, X, W, Sum: Double;
  N: Integer;
begin
  // Prototype of TP_PHASES * TP_TAPS taps at the oversampled rate; phase P takes every
  // TP_PHASES-th tap. Each phase is normalised to unity gain at DC.
  N:=TP_PHASES * TP_TAPS;
  for P:=0 to TP_PHASES - 1 do
  begin
    Sum:=0;
    for K:=0 to TP_TAPS - 1 do
    begin
      // Position of tap K of phase P relative to the filter centre, in input samples.
      T:=(K * TP_PHASES + P - (N - 1) / 2) / TP_PHASES;
      if Abs(T) < 1E-12 then
        X:=1
      else
        X:=Sin(Pi * T) / (Pi * T);
      W:=BesselI0(Beta * Sqrt(Max(0, 1 - Sqr(2 * (K * TP_PHASES + P) / (N - 1) - 1)))) / BesselI0(Beta);
      TruePeakCoef[P][K]:=X * W;
      Sum:=Sum + TruePeakCoef[P][K];
    end;
    for K:=0 to TP_TAPS - 1 do
      TruePeakCoef[P][K]:=TruePeakCoef[P][K] / Sum;
  end;
end;

function DbToLin(ADb: Double): Double;
begin
  Result:=Power(10, ADb / 20);
end;

function LinToDb(AValue: Double): Double;
begin
  if AValue <= 1E-12 then
    Result:=-240
  else
    Result:=20 * Log10(AValue);
end;

function OnePole(ATimeMs: Double; ASampleRate: Integer): Double;
begin
  if ATimeMs <= 0 then
    Result:=0
  else
    Result:=Exp(-1000 / (ATimeMs * ASampleRate));
end;

{ TAudioFilter }

constructor TAudioFilter.Create(const AName: string);
begin
  inherited Create;
  FName:=AName;
  FEnabled:=True;
  FSampleRate:=48000;
  FChannels:=2;
end;

procedure TAudioFilter.Prepare(ASampleRate, AChannels: Integer);
begin
  FSampleRate:=ASampleRate;
  FChannels:=AChannels;
  Reset;
end;

procedure TAudioFilter.Reset;
begin
end;

procedure TAudioFilter.Process(AData: PSingle; AFrames: Integer; ASidechain: PSingle);
begin
  if FEnabled AND (AFrames > 0) then
    DoProcess(AData, AFrames, ASidechain);
end;

function TAudioFilter.Latency: Integer;
begin
  Result:=0;
end;

{ TAudioGainFilter }

constructor TAudioGainFilter.Create(const AName: string);
begin
  inherited Create(AName);
  FApplied:=-1;
end;

procedure TAudioGainFilter.Reset;
begin
  FApplied:=-1;
end;

procedure TAudioGainFilter.DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle);
var
  Target, G0, G: Double;
  F, C: Integer;
  P: PSingle;
begin
  Target:=DbToLin(FGainDb);
  G0:=FApplied;
  if G0 < 0 then
    G0:=Target;
  P:=AData;
  for F:=0 to AFrames - 1 do
  begin
    G:=G0 + (Target - G0) * (F + 1) / AFrames;
    for C:=0 to FChannels - 1 do
    begin
      P^:=P^ * G;
      Inc(P);
    end;
  end;
  FApplied:=Target;
end;

{ TAudioCompressor }

constructor TAudioCompressor.Create(const AName: string);
begin
  inherited Create(AName);
  FThresholdDb:=-18;
  FRatio:=4;
  FAttackMs:=6;
  FReleaseMs:=60;
end;

procedure TAudioCompressor.Reset;
begin
  FEnvelope:=0;
  FReductionDb:=0;
end;

procedure TAudioCompressor.ResetMeter;
begin
  FMaxReductionDb:=0;
end;

function TAudioCompressor.ComputeReductionDb(ALevelDb: Double): Double;
var
  Over, Slope, Knee: Double;
begin
  Slope:=1 - 1 / Max(1, FRatio);
  Over:=ALevelDb - FThresholdDb;
  Knee:=Max(0, FKneeDb);
  if (Knee > 0) AND (Abs(Over) <= Knee / 2) then
    Result:=-Slope * Sqr(Over + Knee / 2) / (2 * Knee)
  else if Over > 0 then
    Result:=-Slope * Over
  else
    Result:=0;
end;

function TAudioCompressor.StaticReductionDb(ALevelDb: Double): Double;
begin
  Result:=ComputeReductionDb(ALevelDb);
end;

procedure TAudioCompressor.DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle);
var
  Att, Rel, Env, X, Makeup, Gain, Red: Double;
  F, C: Integer;
  P, S: PSingle;
begin
  Att:=OnePole(FAttackMs, FSampleRate);
  Rel:=OnePole(FReleaseMs, FSampleRate);
  Makeup:=FMakeupDb;
  Env:=FEnvelope;
  P:=AData;
  if ASidechain <> nil then
    S:=ASidechain
  else
    S:=AData;
  Red:=FReductionDb;
  for F:=0 to AFrames - 1 do
  begin
    X:=0;
    for C:=0 to FChannels - 1 do
    begin
      X:=Max(X, Abs(S^));
      Inc(S);
    end;
    if X > Env then
      Env:=Att * Env + (1 - Att) * X
    else
      Env:=Rel * Env + (1 - Rel) * X;
    Red:=ComputeReductionDb(LinToDb(Env));
    Gain:=DbToLin(Red + Makeup);
    for C:=0 to FChannels - 1 do
    begin
      P^:=P^ * Gain;
      Inc(P);
    end;
    if Red < FMaxReductionDb then
      FMaxReductionDb:=Red;
  end;
  FEnvelope:=Env;
  FReductionDb:=Red;
end;

{ TAudioLimiter }

constructor TAudioLimiter.Create(const AName: string);
begin
  inherited Create(AName);
  FCeilingDb:=-1;
  FReleaseMs:=60;
  FLookaheadMs:=1.5;
  FTruePeak:=True;
  FWindow:=-1;
end;

procedure TAudioLimiter.Prepare(ASampleRate, AChannels: Integer);
begin
  FSampleRate:=ASampleRate;
  FChannels:=AChannels;
  FWindow:=-1;
  Build;
end;

procedure TAudioLimiter.Reset;
begin
  FWindow:=-1;
  Build;
end;

procedure TAudioLimiter.ResetMeter;
begin
  FMaxReductionDb:=0;
end;

procedure TAudioLimiter.Build;
var
  I: Integer;
begin
  FWindow:=WindowFrames;
  FBuiltTruePeak:=FTruePeak;
  if FTruePeak then
    FPeakDelay:=TP_TAPS DIV 2
  else
    FPeakDelay:=0;
  FDelay:=FWindow - 1 + FPeakDelay;
  SetLength(FLine, Max(1, FDelay) * FChannels);
  for I:=0 to High(FLine) do
    FLine[I]:=0;
  FLinePos:=0;
  SetLength(FHistory, 2 * TP_TAPS * FChannels);
  for I:=0 to High(FHistory) do
    FHistory[I]:=0;
  FHistoryPos:=0;
  SetLength(FMinIndex, FWindow + 1);
  SetLength(FMinValue, FWindow + 1);
  FMinHead:=0;
  FMinCount:=0;
  SetLength(FAvgRing, FWindow);
  for I:=0 to High(FAvgRing) do
    FAvgRing[I]:=1;
  FAvgPos:=0;
  FAvgSum:=FWindow;
  FAvgCount:=0;
  FSample:=0;
  FGain:=1;
  FReductionDb:=0;
end;

function TAudioLimiter.WindowFrames: Integer;
begin
  Result:=Max(1, Round(FLookaheadMs * FSampleRate / 1000));
end;

function TAudioLimiter.NeedsBuild: Boolean;
begin
  Result:=(FWindow <> WindowFrames) OR (FBuiltTruePeak <> FTruePeak) OR (Length(FHistory) <> 2 * TP_TAPS * FChannels);
end;

function TAudioLimiter.Latency: Integer;
begin
  if NOT Enabled then
    Result:=0
  else
    Result:=WindowFrames - 1 + Ord(FTruePeak) * (TP_TAPS DIV 2);
end;

procedure TAudioLimiter.DoProcess(AData: PSingle; AFrames: Integer; ASidechain: PSingle);
var
  F, C, K, P, Idx, Taps: Integer;
  Ceiling, Peak, Target, M, Avg, Rel, V, Y: Double;
  Src, Dst: PSingle;
  H, Q: PDouble;
begin
  if NeedsBuild then
    Build;
  Ceiling:=DbToLin(FCeilingDb);
  Rel:=OnePole(FReleaseMs, FSampleRate);
  Taps:=TP_TAPS;
  Src:=AData;
  if ASidechain <> nil then
    Src:=ASidechain;
  Dst:=AData;
  for F:=0 to AFrames - 1 do
  begin
    // Detector: true peak (4x) or sample peak over all channels, of this input frame.
    Peak:=0;
    for C:=0 to FChannels - 1 do
    begin
      V:=PSingle(PByte(Src) + (F * FChannels + C) * SizeOf(Single))^;
      if FBuiltTruePeak then
      begin
        FHistory[FHistoryPos * FChannels + C]:=V;
        FHistory[(FHistoryPos + Taps) * FChannels + C]:=V;
        // Newest frame at Newest, tap K reads the frame K before it; no wrap in the doubled ring.
        H:=@FHistory[(FHistoryPos + Taps) * FChannels + C];
        // Phases 0..3 between the samples around the filter centre.
        for P:=0 to TP_PHASES - 1 do
        begin
          Y:=0;
          Q:=H;
          for K:=0 to Taps - 1 do
          begin
            Y:=Y + TruePeakCoef[P][K] * Q^;
            Dec(Q, FChannels);
          end;
          if Abs(Y) > Peak then
            Peak:=Abs(Y);
        end;
        // The two input samples around the filter centre: the sample peak is always covered.
        Idx:=(Taps DIV 2) * FChannels;
        Peak:=Max(Peak, Abs(PDouble(PByte(H) - Idx * SizeOf(Double))^));
        Peak:=Max(Peak, Abs(PDouble(PByte(H) - (Idx - FChannels) * SizeOf(Double))^));
      end else
        Peak:=Max(Peak, Abs(V));
    end;
    if FBuiltTruePeak then
      FHistoryPos:=(FHistoryPos + 1) MOD Taps;
    if Peak > Ceiling then
      Target:=Ceiling / Peak
    else
      Target:=1;

    // Sliding minimum over the last FWindow targets.
    while (FMinCount > 0) AND (FMinValue[(FMinHead + FMinCount - 1) MOD Length(FMinValue)] >= Target) do
      Dec(FMinCount);
    FMinIndex[(FMinHead + FMinCount) MOD Length(FMinIndex)]:=FSample;
    FMinValue[(FMinHead + FMinCount) MOD Length(FMinValue)]:=Target;
    Inc(FMinCount);
    while FMinIndex[FMinHead] <= FSample - FWindow do
    begin
      FMinHead:=(FMinHead + 1) MOD Length(FMinIndex);
      Dec(FMinCount);
    end;
    M:=FMinValue[FMinHead];

    // Moving average of the minimum over FWindow samples.
    FAvgSum:=FAvgSum - FAvgRing[FAvgPos] + M;
    FAvgRing[FAvgPos]:=M;
    FAvgPos:=(FAvgPos + 1) MOD FWindow;
    Inc(FAvgCount);
    if FAvgCount >= 65536 then
    begin
      // Re-sum now and then so rounding never accumulates.
      FAvgSum:=0;
      for K:=0 to FWindow - 1 do
        FAvgSum:=FAvgSum + FAvgRing[K];
      FAvgCount:=0;
    end;
    Avg:=Min(1, FAvgSum / FWindow);

    // Down at once (the average already ramps), up with the release.
    if Avg < FGain then
      FGain:=Avg
    else
      FGain:=Avg + (FGain - Avg) * Rel;
    Inc(FSample);

    // Delay line: out = the frame from FDelay frames ago, times the gain.
    for C:=0 to FChannels - 1 do
    begin
      V:=PSingle(PByte(AData) + (F * FChannels + C) * SizeOf(Single))^;
      if FDelay > 0 then
      begin
        Y:=FLine[FLinePos * FChannels + C];
        FLine[FLinePos * FChannels + C]:=V;
      end else
        Y:=V;
      Dst^:=Y * FGain;
      Inc(Dst);
    end;
    if FDelay > 0 then
      FLinePos:=(FLinePos + 1) MOD FDelay;
    V:=LinToDb(FGain);
    if V < FMaxReductionDb then
      FMaxReductionDb:=V;
  end;
  FReductionDb:=LinToDb(FGain);
end;

initialization
  BuildTruePeakCoefficients;

end.
