unit TAudio.ClockSync;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$POINTERMATH ON}

{
  Locks a capture device's sample clock to a reference clock.

  Every captured packet carries the reference time (e.g. the WASAPI QPC position,
  see TAudio.Clock) at which its first frame was recorded. TAudioClockSync fits a
  line through (input position, capture time) over a sliding window, which gives
  the device's true sample rate against the reference, and resamples the input so
  that output frame k belongs to reference time

      OriginUs + k * 1e6 / NominalRate

  exactly. The resampling ratio follows the fitted rate plus a small correction
  that pulls the remaining position error to zero over ResponseSeconds; it never
  leaves 1 +/- MaxCorrectionPpm. Only errors above ResyncThresholdMs (a device
  stall, a dropped buffer, a clock jump) are fixed by skipping input or inserting
  silence, and every such event is counted. In normal operation no samples are
  dropped or invented.

  A capture-time gap larger than the threshold (e.g. loopback capture of an idle
  render stream delivers nothing) is bridged with silence at the device rate, so
  the input timeline stays continuous.

  Interleaved Float32 in and out. Not thread-safe: call from one thread.

  FPC note: MINFPCONSTPREC 64 is required. FPC otherwise types 1E6 as Single, and
  K * (1E6 / rate) then loses microseconds after a few hours of frames.
}

interface

uses
{$IFDEF FPC}
  SysUtils, Math,
{$ELSE}
  System.SysUtils, System.Math,
{$ENDIF}
  TAudio.Resample;

type
  TAudioClockSyncStats = record
    Converged: Boolean;
    DeviceRateHz: Double;
    DriftPpm: Double;
    CorrectionPpm: Double;
    ErrorUs: Double;
    MaxAbsErrorUs: Double;       // since convergence
    Resyncs: Integer;
    SkippedFrames: Int64;
    SilenceInputFrames: Int64;   // gap fill and resync padding on the input side
    SilenceOutputFrames: Int64;  // resync padding on the output side
    InputFrames: Int64;          // device frames received
    OutputFrames: Int64;
    FitPoints: Integer;
  end;

  TAudioClockSync = class
  private
    FChannels: Integer;
    FNominalRate: Integer;
    FResampler: TAudioVariableResampler;
    FMaxCorrectionPpm: Double;
    FWindowSeconds: Double;
    FResponseSeconds: Double;
    FResyncThresholdMs: Double;
    FConvergeSeconds: Double;
    FStarted: Boolean;
    FOriginUs: Int64;
    // Fit points: input position (resampler coordinates) and capture time relative to origin.
    FPointN: array of Double;
    FPointT: array of Double;
    FPointHead, FPointCount: Integer;
    FSlope: Double;   // microseconds per input frame
    FIntercept: Double;
    FStats: TAudioClockSyncStats;
    FScratch: TArray<Single>;
    procedure AddPoint(N, T: Double);
    procedure Fit;
    function PredictTime(N: Double): Double;
    function PositionAt(T: Double): Double;
    function OutputTimeUs(K: Int64): Double;
  public
    constructor Create(Channels, NominalRate: Integer; CountOnly: Boolean = False);
    destructor Destroy; override;
    // Feeds one captured packet. Returns the number of output frames appended to
    // Output at index OutputOffset (in frames); Output grows as needed.
    // TimestampValid = False (WASAPI AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) keeps the packet out of
    // the fit and the gap check; its frames still play.
    function Push(Data: PSingle; Frames: Integer; CaptureTimeUs: Int64; var Output: TArray<Single>;
      OutputOffset: Integer = 0; TimestampValid: Boolean = True): Integer;
    function Stats: TAudioClockSyncStats;
    // Reference time of output frame K (microseconds).
    function OutputFrameTimeUs(K: Int64): Int64;
    property Channels: Integer read FChannels;
    property NominalRate: Integer read FNominalRate;
    // Reference time of output frame 0: the capture time of the first packet.
    property OriginUs: Int64 read FOriginUs;
    property Started: Boolean read FStarted;
    // Input position (input frames incl. inserted silence) the next output frame reads from,
    // and that frame's index; for measuring the true alignment in tests.
    function NextInputPosition: Double;
    function NextOutputFrame: Int64;
    property MaxCorrectionPpm: Double read FMaxCorrectionPpm write FMaxCorrectionPpm;
    property WindowSeconds: Double read FWindowSeconds write FWindowSeconds;
    property ResponseSeconds: Double read FResponseSeconds write FResponseSeconds;
    property ResyncThresholdMs: Double read FResyncThresholdMs write FResyncThresholdMs;
    // Time after start before MaxAbsErrorUs is tracked.
    property ConvergeSeconds: Double read FConvergeSeconds write FConvergeSeconds;
  end;

implementation

const
  MaxPoints = 8192;

constructor TAudioClockSync.Create(Channels, NominalRate: Integer; CountOnly: Boolean);
begin
  inherited Create;
  if NominalRate <= 0 then
    raise EArgumentException.Create('Nominal rate must be positive');
  FChannels:=Channels;
  FNominalRate:=NominalRate;
  FResampler:=TAudioVariableResampler.Create(Channels, CountOnly);
  FMaxCorrectionPpm:=2000;
  FWindowSeconds:=30;
  FResponseSeconds:=2;
  FResyncThresholdMs:=40;
  FConvergeSeconds:=10;
  SetLength(FPointN, MaxPoints);
  SetLength(FPointT, MaxPoints);
  FSlope:=1E6 / NominalRate;
end;

destructor TAudioClockSync.Destroy;
begin
  FResampler.Free;
  inherited Destroy;
end;

procedure TAudioClockSync.AddPoint(N, T: Double);
var
  Newest: Double;
begin
  if FPointCount = MaxPoints then
  begin
    FPointHead:=(FPointHead + 1) MOD MaxPoints;
    Dec(FPointCount);
  end;
  FPointN[(FPointHead + FPointCount) MOD MaxPoints]:=N;
  FPointT[(FPointHead + FPointCount) MOD MaxPoints]:=T;
  Inc(FPointCount);
  Newest:=T;
  while (FPointCount > 2) AND (Newest - FPointT[FPointHead] > FWindowSeconds * 1E6) do
  begin
    FPointHead:=(FPointHead + 1) MOD MaxPoints;
    Dec(FPointCount);
  end;
end;

procedure TAudioClockSync.Fit;
var
  I, J: Integer;
  MeanN, MeanT, Snn, Snt, DN: Double;
  Span: Double;
begin
  if FPointCount = 0 then
    Exit;
  MeanN:=0;
  MeanT:=0;
  for I:=0 to FPointCount - 1 do
  begin
    J:=(FPointHead + I) MOD MaxPoints;
    MeanN:=MeanN + FPointN[J];
    MeanT:=MeanT + FPointT[J];
  end;
  MeanN:=MeanN / FPointCount;
  MeanT:=MeanT / FPointCount;
  Span:=FPointT[(FPointHead + FPointCount - 1) MOD MaxPoints] - FPointT[FPointHead];
  // Until a second of history exists, keep the previous (initially nominal) slope.
  if (FPointCount >= 10) AND (Span >= 1E6) then
  begin
    Snn:=0;
    Snt:=0;
    for I:=0 to FPointCount - 1 do
    begin
      J:=(FPointHead + I) MOD MaxPoints;
      DN:=FPointN[J] - MeanN;
      Snn:=Snn + DN * DN;
      Snt:=Snt + DN * (FPointT[J] - MeanT);
    end;
    if Snn > 0 then
      FSlope:=Snt / Snn;
  end;
  FIntercept:=MeanT - FSlope * MeanN;
end;

function TAudioClockSync.PredictTime(N: Double): Double;
begin
  Result:=FIntercept + FSlope * N;
end;

function TAudioClockSync.PositionAt(T: Double): Double;
begin
  Result:=(T - FIntercept) / FSlope;
end;

function TAudioClockSync.OutputTimeUs(K: Int64): Double;
begin
  Result:=K * (1E6 / FNominalRate);
end;

function TAudioClockSync.OutputFrameTimeUs(K: Int64): Int64;
begin
  Result:=FOriginUs + Round(OutputTimeUs(K));
end;

function TAudioClockSync.Push(Data: PSingle; Frames: Integer; CaptureTimeUs: Int64; var Output: TArray<Single>;
  OutputOffset: Integer; TimestampValid: Boolean): Integer;
var
  T, Gap, ErrorFrames, Step, MaxDelta, Target: Double;
  GapFrames, Pad: Integer;
  Produced, C: Integer;
  Need: Integer;
begin
  Result:=0;
  if Frames <= 0 then
    Exit;
  if NOT FStarted then
  begin
    if NOT TimestampValid then
      Exit; // no reliable origin yet; wait for a good timestamp
    FStarted:=True;
    FOriginUs:=CaptureTimeUs;
  end;
  T:=CaptureTimeUs - FOriginUs;

  // Gap in capture time beyond the threshold: bridge it with silence so the line stays continuous.
  if TimestampValid AND (FPointCount > 0) then
  begin
    Gap:=T - PredictTime(FResampler.InputFrames);
    if Gap > FResyncThresholdMs * 1000 then
    begin
      GapFrames:=Round(Gap / FSlope);
      FResampler.InsertSilence(GapFrames);
      Inc(FStats.SilenceInputFrames, GapFrames);
      Inc(FStats.Resyncs);
    end;
  end;
  // A timestamp far behind the fit is a clock glitch, not drift; keep it out of the fit.
  if TimestampValid AND ((FPointCount = 0) OR (PredictTime(FResampler.InputFrames) - T <= FResyncThresholdMs * 1000)) then
    AddPoint(FResampler.InputFrames, T);
  Fit;

  // Position error at the next output frame.
  Target:=PositionAt(OutputTimeUs(FResampler.OutputFrames + FStats.SilenceOutputFrames));
  ErrorFrames:=FResampler.InputPosition - Target;
  FStats.ErrorUs:=ErrorFrames * FSlope;
  if Abs(FStats.ErrorUs) > FResyncThresholdMs * 1000 then
  begin
    Inc(FStats.Resyncs);
    if ErrorFrames < 0 then
    begin
      // Reading behind the device: drop the backlog.
      FResampler.SkipInput(Round(-ErrorFrames));
      Inc(FStats.SkippedFrames, Round(-ErrorFrames));
    end else
    begin
      // Reading ahead of the device: pad the output with silence.
      Pad:=Round(ErrorFrames * FSlope * FNominalRate / 1E6);
      Need:=(OutputOffset + Pad) * FChannels;
      if Length(Output) < Need then
        SetLength(Output, Need);
      for C:=OutputOffset * FChannels to Need - 1 do
        Output[C]:=0;
      // The padding is output, so output time advances past it.
      Inc(OutputOffset, Pad);
      Inc(Result, Pad);
      Inc(FStats.SilenceOutputFrames, Pad);
    end;
    Target:=PositionAt(OutputTimeUs(FResampler.OutputFrames + FStats.SilenceOutputFrames));
    ErrorFrames:=FResampler.InputPosition - Target;
  end;

  // Base ratio from the fit, plus a correction that removes the error over ResponseSeconds.
  Step:=(1E6 / FNominalRate) / FSlope - ErrorFrames / (FResponseSeconds * FNominalRate);
  MaxDelta:=FMaxCorrectionPpm * 1E-6;
  Step:=EnsureRange(Step, 1 - MaxDelta, 1 + MaxDelta);
  FResampler.Step:=Step;

  Produced:=FResampler.Process(Data, Frames, FScratch);
  if Produced > 0 then
  begin
    Need:=(OutputOffset + Produced) * FChannels;
    if Length(Output) < Need then
      SetLength(Output, Need);
    if Length(FScratch) > 0 then
      Move(FScratch[0], Output[OutputOffset * FChannels], Produced * FChannels * SizeOf(Single));
    Inc(Result, Produced);
  end;

  Inc(FStats.InputFrames, Frames);
  FStats.OutputFrames:=FResampler.OutputFrames + FStats.SilenceOutputFrames;
  FStats.DeviceRateHz:=1E6 / FSlope;
  FStats.DriftPpm:=(FStats.DeviceRateHz / FNominalRate - 1) * 1E6;
  FStats.CorrectionPpm:=(Step - 1) * 1E6;
  FStats.FitPoints:=FPointCount;
  FStats.Converged:=T >= FConvergeSeconds * 1E6;
  if FStats.Converged AND (Abs(FStats.ErrorUs) > FStats.MaxAbsErrorUs) then
    FStats.MaxAbsErrorUs:=Abs(FStats.ErrorUs);
end;

function TAudioClockSync.NextInputPosition: Double;
begin
  Result:=FResampler.InputPosition;
end;

function TAudioClockSync.NextOutputFrame: Int64;
begin
  Result:=FResampler.OutputFrames + FStats.SilenceOutputFrames;
end;

function TAudioClockSync.Stats: TAudioClockSyncStats;
begin
  Result:=FStats;
end;

end.
