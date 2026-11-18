unit TAudio.Resample;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$POINTERMATH ON}

{
  Variable-ratio resampler for interleaved Float32 PCM.

  Kaiser-windowed sinc, 32 taps, 1024 phases with linear interpolation between
  phases; every phase is normalised to unity DC gain. Step (input samples per
  output sample) may change between calls, which is what clock-drift
  compensation needs: ratios within a few thousand ppm of 1.

  InputPosition is the absolute, fractional input sample index the next output
  sample will be taken from (sample 0 = first input sample). SkipInput and
  InsertSilence move that mapping for hard resyncs.

  CountOnly computes output sample counts and positions without any DSP or
  buffering, for long simulations of the clock controller.
}

interface

uses
{$IFDEF FPC}
  SysUtils, Math;
{$ELSE}
  System.SysUtils, System.Math;
{$ENDIF}

type
  TAudioVariableResampler = class
  private
    const
      HalfTaps = 16;
      Taps = 2 * HalfTaps;
      Phases = 1024;
    var
      FChannels: Integer;
      FCountOnly: Boolean;
      FCoeffs: array of Single;          // (Phases + 1) * Taps
      FStep: Double;
      // Input history: FHistory[0] is absolute input sample FBase.
      FHistory: array of Single;
      FHistoryFrames: Integer;
      FBase: Int64;
      // Next output position relative to FBase: integer part and fraction.
      FIndex: Int64;
      FFrac: Double;
      FInputFrames: Int64;
      FOutputFrames: Int64;
    procedure BuildTable;
    procedure Compact;
    function GetInputPosition: Double;
  public
    constructor Create(Channels: Integer; CountOnly: Boolean = False);
    // Appends Frames input frames and returns output frames. Output receives
    // interleaved samples (resized as needed; unused when CountOnly).
    function Process(Input: PSingle; Frames: Integer; var Output: TArray<Single>): Integer;
    // Drops input frames from the mapping (the device ran ahead).
    procedure SkipInput(Frames: Int64);
    // Adds silent input frames (the device fell behind or stalled).
    procedure InsertSilence(Frames: Integer);
    procedure Reset;
    property Channels: Integer read FChannels;
    property Step: Double read FStep write FStep;
    property InputPosition: Double read GetInputPosition;
    property InputFrames: Int64 read FInputFrames;
    property OutputFrames: Int64 read FOutputFrames;
    // Delay in input frames between the newest input and the next output.
    function BufferedInputFrames: Double;
  end;

implementation

function BesselI0(X: Double): Double;
var
  Sum, Term, Half: Double;
  K: Integer;
begin
  Sum:=1;
  Term:=1;
  Half:=X / 2;
  for K:=1 to 50 do
  begin
    Term:=Term * (Half / K) * (Half / K);
    Sum:=Sum + Term;
    if Term < Sum * 1E-12 then
      Break;
  end;
  Result:=Sum;
end;

constructor TAudioVariableResampler.Create(Channels: Integer; CountOnly: Boolean);
begin
  inherited Create;
  if Channels < 1 then
    raise EArgumentException.Create('Resampler needs at least one channel');
  FChannels:=Channels;
  FCountOnly:=CountOnly;
  FStep:=1.0;
  if NOT FCountOnly then
    BuildTable;
  Reset;
end;

procedure TAudioVariableResampler.BuildTable;
const
  Beta = 8.6;
  Cutoff = 0.475; // cycles per sample; just under Nyquist for ratios near 1
var
  P, T: Integer;
  X, W, Sinc, Sum, Norm: Double;
  Row: array[0..Taps - 1] of Double;
begin
  SetLength(FCoeffs, (Phases + 1) * Taps);
  Norm:=BesselI0(Beta);
  for P:=0 to Phases do
  begin
    Sum:=0;
    for T:=0 to Taps - 1 do
    begin
      // Tap T covers input sample Index - HalfTaps + 1 + T; fractional offset P / Phases.
      X:=(T - (HalfTaps - 1)) - P / Phases;
      if Abs(X) < 1E-12 then
        Sinc:=2 * Cutoff
      else
        Sinc:=Sin(2 * Pi * Cutoff * X) / (Pi * X);
      W:=1 - Sqr(X / HalfTaps);
      if W < 0 then
        W:=0
      else
        W:=BesselI0(Beta * Sqrt(W)) / Norm;
      Row[T]:=Sinc * W;
      Sum:=Sum + Row[T];
    end;
    for T:=0 to Taps - 1 do
      FCoeffs[P * Taps + T]:=Row[T] / Sum;
  end;
end;

procedure TAudioVariableResampler.Reset;
begin
  FBase:=-(HalfTaps - 1);
  // History starts with HalfTaps - 1 zero frames so output 0 maps to input 0.
  FHistoryFrames:=HalfTaps - 1;
  if NOT FCountOnly then
  begin
    SetLength(FHistory, 4096 * FChannels);
    FillChar(FHistory[0], FHistoryFrames * FChannels * SizeOf(Single), 0);
  end;
  FIndex:=HalfTaps - 1;
  FFrac:=0;
  FInputFrames:=0;
  FOutputFrames:=0;
end;

function TAudioVariableResampler.GetInputPosition: Double;
begin
  Result:=FBase + FIndex + FFrac;
end;

function TAudioVariableResampler.BufferedInputFrames: Double;
begin
  Result:=FInputFrames - InputPosition;
end;

procedure TAudioVariableResampler.Compact;
var
  Keep, Drop: Integer;
begin
  // Keep everything from the first tap of the next output onwards.
  Drop:=Integer(FIndex) - (HalfTaps - 1);
  if Drop <= 0 then
    Exit;
  if Drop > FHistoryFrames then
    Drop:=FHistoryFrames;
  Keep:=FHistoryFrames - Drop;
  if (NOT FCountOnly) AND (Keep > 0) then
    Move(FHistory[Drop * FChannels], FHistory[0], Keep * FChannels * SizeOf(Single));
  FHistoryFrames:=Keep;
  Inc(FBase, Drop);
  Dec(FIndex, Drop);
end;

function TAudioVariableResampler.Process(Input: PSingle; Frames: Integer; var Output: TArray<Single>): Integer;
var
  Need, OutCap, C, T: Integer;
  PhasePos, Blend: Double;
  Phase: Integer;
  C0, C1: PSingle;
  Src: PSingle;
  Acc: array[0..31] of Double;
  Coeff: Single;
  WholeSteps: Int64;
begin
  Result:=0;
  if Frames < 0 then
    raise EArgumentException.Create('Negative frame count');
  if FStep <= 0 then
    raise EArgumentException.Create('Resampler step must be positive');
  if FChannels > Length(Acc) then
    raise EArgumentException.Create('Resampler supports at most 32 channels');
  // Append input.
  if NOT FCountOnly then
  begin
    Need:=(FHistoryFrames + Frames) * FChannels;
    if Need > Length(FHistory) then
      SetLength(FHistory, Need * 2);
    if Frames > 0 then
      Move(Input^, FHistory[FHistoryFrames * FChannels], Frames * FChannels * SizeOf(Single));
  end;
  Inc(FHistoryFrames, Frames);
  Inc(FInputFrames, Frames);

  OutCap:=Length(Output) DIV FChannels;
  // An output needs input samples up to FIndex + HalfTaps.
  while FIndex + HalfTaps < FHistoryFrames do
  begin
    if NOT FCountOnly then
    begin
      if Result >= OutCap then
      begin
        OutCap:=Max(256, OutCap * 2);
        SetLength(Output, OutCap * FChannels);
      end;
      PhasePos:=FFrac * Phases;
      Phase:=Trunc(PhasePos);
      if Phase >= Phases then
        Phase:=Phases - 1;
      Blend:=PhasePos - Phase;
      C0:=@FCoeffs[Phase * Taps];
      C1:=@FCoeffs[(Phase + 1) * Taps];
      for C:=0 to FChannels - 1 do
        Acc[C]:=0;
      Src:=@FHistory[(FIndex - (HalfTaps - 1)) * FChannels];
      for T:=0 to Taps - 1 do
      begin
        Coeff:=C0[T] + (C1[T] - C0[T]) * Blend;
        for C:=0 to FChannels - 1 do
          Acc[C]:=Acc[C] + Coeff * Src[T * FChannels + C];
      end;
      for C:=0 to FChannels - 1 do
        Output[Result * FChannels + C]:=Acc[C];
    end;
    Inc(Result);
    FFrac:=FFrac + FStep;
    WholeSteps:=Trunc(FFrac);
    FFrac:=FFrac - WholeSteps;
    Inc(FIndex, WholeSteps);
  end;
  Inc(FOutputFrames, Result);
  Compact;
end;

procedure TAudioVariableResampler.SkipInput(Frames: Int64);
begin
  if Frames <= 0 then
    Exit;
  Inc(FIndex, Frames);
  // Skipped frames may not have arrived yet; Process waits until the taps are filled.
  Compact;
end;

procedure TAudioVariableResampler.InsertSilence(Frames: Integer);
var
  Zeros: TArray<Single>;
begin
  if Frames <= 0 then
    Exit;
  // Silence enters at the input end, so it plays after what is already buffered.
  if FCountOnly then
  begin
    Inc(FHistoryFrames, Frames);
    Inc(FInputFrames, Frames);
    Exit;
  end;
  SetLength(Zeros, Frames * FChannels);
  if Frames > 0 then
    FillChar(Zeros[0], Length(Zeros) * SizeOf(Single), 0);
  // Append without producing output here; the caller's next Process emits it.
  if (FHistoryFrames + Frames) * FChannels > Length(FHistory) then
    SetLength(FHistory, (FHistoryFrames + Frames) * FChannels * 2);
  Move(Zeros[0], FHistory[FHistoryFrames * FChannels], Length(Zeros) * SizeOf(Single));
  Inc(FHistoryFrames, Frames);
  Inc(FInputFrames, Frames);
end;

end.
