program AudioDynamicsSmoke;

{$APPTYPE CONSOLE}

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}

{
  TAudio.Dynamics and the mixer's filter chain.

  Compressor: the static curve (hard and soft knee) exactly on steady levels,
  a sine within the detector's ripple, attack and release timing, makeup, and
  the sidechain. Limiter: transparent below the ceiling (output = input delayed
  by exactly Latency), the sample-peak ceiling under random noise 12 dB over it
  with random block sizes, the true-peak ceiling against a 16x reference
  interpolator, release. Mixer: a limited input and an inverted copy without
  filters cancel (latency compensation), sidechain ducking, a muted sidechain,
  cycles rejected, removing a sidechain input.
}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  Math,
  SysUtils,
  TAudio.Dynamics,
  TAudio.Mixer;

const
  Fs = 48000;
  Block = 480;

var
  PassCount: Integer = 0;
  FailCount: Integer = 0;

procedure Check(ACondition: Boolean; const AMessage: string);
begin
  if ACondition then
  begin
    Inc(PassCount);
    Writeln('PASS ', AMessage);
  end else
  begin
    Inc(FailCount);
    Writeln('FAIL ', AMessage);
  end;
end;

function Db(AValue: Double): Double;
begin
  Result:=20 * Log10(Max(Abs(AValue), 1E-12));
end;

function Lin(ADb: Double): Double;
begin
  Result:=Power(10, ADb / 20);
end;

// Stereo, both channels the same value.
procedure FillConst(var ABuf: TArray<Single>; AFrames: Integer; AValue: Double);
var
  I: Integer;
begin
  SetLength(ABuf, AFrames * 2);
  for I:=0 to AFrames * 2 - 1 do
    ABuf[I]:=AValue;
end;

procedure FillSine(var ABuf: TArray<Single>; AStart: Int64; AFrames: Integer; AFreq, AAmp, APhase: Double);
var
  I: Integer;
begin
  SetLength(ABuf, AFrames * 2);
  for I:=0 to AFrames - 1 do
  begin
    ABuf[I * 2]:=AAmp * Sin(2 * Pi * AFreq * (AStart + I) / Fs + APhase);
    ABuf[I * 2 + 1]:=ABuf[I * 2];
  end;
end;

// Steady level through a compressor for ASeconds; returns the last output sample's level in dB.
function CompressConst(AComp: TAudioCompressor; ALevelDb: Double; ASeconds: Double): Double;
var
  Buf: TArray<Single>;
  I, Blocks: Integer;
begin
  Blocks:=Round(ASeconds * Fs / Block);
  Result:=0;
  for I:=1 to Blocks do
  begin
    FillConst(Buf, Block, Lin(ALevelDb));
    AComp.Process(@Buf[0], Block);
    Result:=Db(Buf[High(Buf)]);
  end;
end;

procedure TestCompressorStatic;
var
  Comp: TAudioCompressor;
  L, Got, Want, Worst: Double;
  Levels: array[0..7] of Double;
  I: Integer;
begin
  Levels[0]:=-40; Levels[1]:=-30; Levels[2]:=-21; Levels[3]:=-20; Levels[4]:=-19; Levels[5]:=-12; Levels[6]:=-6; Levels[7]:=0;
  Comp:=TAudioCompressor.Create;
  try
    Comp.Prepare(Fs, 2);
    Comp.ThresholdDb:=-20;
    Comp.Ratio:=4;
    Comp.AttackMs:=1;
    Comp.ReleaseMs:=50;
    Worst:=0;
    for I:=0 to High(Levels) do
    begin
      L:=Levels[I];
      Got:=CompressConst(Comp, L, 1);
      if L > -20 then
        Want:=-20 + (L + 20) / 4
      else
        Want:=L;
      Worst:=Max(Worst, Abs(Got - Want));
    end;
    Check(Worst < 0.01, Format('compressor static curve, hard knee, -20 dB 4:1, -40..0 dB in: max error %.4f dB', [Worst]));

    // Soft knee 6 dB: quadratic inside +-3 dB, continuous with the hard curve at its edges.
    Comp.KneeDb:=6;
    Worst:=0;
    for I:=0 to High(Levels) do
    begin
      L:=Levels[I];
      Got:=CompressConst(Comp, L, 1);
      if Abs(L + 20) <= 3 then
        Want:=L - 0.75 * Sqr(L + 20 + 3) / 12
      else if L > -20 then
        Want:=-20 + (L + 20) / 4
      else
        Want:=L;
      Worst:=Max(Worst, Abs(Got - Want));
    end;
    Check(Worst < 0.01, Format('compressor static curve, 6 dB soft knee: max error %.4f dB', [Worst]));
    Check((Abs(Comp.StaticReductionDb(-17) - (-0.75 * 3)) < 1E-9) AND (Abs(Comp.StaticReductionDb(-23)) < 1E-9),
      'soft knee meets the hard curve at both edges');

    Comp.KneeDb:=0;
    Comp.MakeupDb:=6;
    Got:=CompressConst(Comp, -30, 0.5);
    Check(Abs(Got - (-24)) < 0.01, Format('makeup gain +6 dB below the threshold: -30 -> %.3f dB', [Got]));
  finally
    Comp.Free;
  end;
end;

procedure TestCompressorSine;
var
  Comp: TAudioCompressor;
  Buf: TArray<Single>;
  I, J, Blocks: Integer;
  Peak, Want: Double;
begin
  Comp:=TAudioCompressor.Create;
  try
    Comp.Prepare(Fs, 2);
    Comp.ThresholdDb:=-20;
    Comp.Ratio:=4;
    Comp.AttackMs:=5;
    Comp.ReleaseMs:=200;
    Blocks:=Fs DIV Block;
    Peak:=0;
    for I:=0 to Blocks - 1 do
    begin
      FillSine(Buf, Int64(I) * Block, Block, 1000, Lin(-5), 0);
      Comp.Process(@Buf[0], Block);
      if I >= Blocks - 10 then
        for J:=0 to High(Buf) do
          Peak:=Max(Peak, Abs(Buf[J]));
    end;
    Want:=-20 + 15 / 4;
    // A peak envelope with 5 ms attack settles a few tenths of a dB under a sine's peak.
    Check(Abs(Db(Peak) - Want) < 0.5, Format('compressor on a -5 dB 1 kHz sine: output peak %.2f dB (curve %.2f dB; detector ripple)',
      [Db(Peak), Want]));
  finally
    Comp.Free;
  end;
end;

procedure TestCompressorTiming;
var
  Comp: TAudioCompressor;
  Buf: TArray<Single>;
  Early, Settled, Released, Holding: Double;
  I: Integer;
begin
  Comp:=TAudioCompressor.Create;
  try
    Comp.Prepare(Fs, 2);
    Comp.ThresholdDb:=-20;
    Comp.Ratio:=10;
    Comp.AttackMs:=10;
    Comp.ReleaseMs:=100;
    CompressConst(Comp, -40, 0.5);
    // Step to -10 dB: target reduction -9 dB.
    FillConst(Buf, 48, Lin(-10));
    Comp.Process(@Buf[0], 48);
    Early:=Comp.ReductionDb;
    FillConst(Buf, 2400 - 48, Lin(-10));
    Comp.Process(@Buf[0], Length(Buf) DIV 2);
    Settled:=Comp.ReductionDb;
    Check((Early > -3) AND (Abs(Settled - (-9)) < 0.1), Format('attack 10 ms: %.2f dB after 1 ms, %.2f dB after 50 ms (target -9 dB)',
      [Early, Settled]));
    // Back to -40 dB.
    FillConst(Buf, 480, Lin(-40));
    Comp.Process(@Buf[0], 480);
    Holding:=Comp.ReductionDb;
    for I:=1 to 50 do
    begin
      FillConst(Buf, 480, Lin(-40));
      Comp.Process(@Buf[0], 480);
    end;
    Released:=Comp.ReductionDb;
    Check((Holding < -6) AND (Released > -0.01), Format('release 100 ms: %.2f dB after 10 ms, %.3f dB after 510 ms', [Holding, Released]));
  finally
    Comp.Free;
  end;
end;

procedure TestCompressorSidechain;
var
  Comp: TAudioCompressor;
  Buf, Side: TArray<Single>;
  I: Integer;
  Ducked, Free_: Double;
begin
  Comp:=TAudioCompressor.Create;
  try
    Comp.Prepare(Fs, 2);
    Comp.ThresholdDb:=-30;
    Comp.Ratio:=10;
    Comp.AttackMs:=1;
    Comp.ReleaseMs:=50;
    for I:=1 to 50 do
    begin
      FillConst(Buf, Block, Lin(-10));
      FillConst(Side, Block, Lin(-10));
      Comp.Process(@Buf[0], Block, @Side[0]);
    end;
    Ducked:=Db(Buf[High(Buf)]);
    for I:=1 to 50 do
    begin
      FillConst(Buf, Block, Lin(-10));
      FillConst(Side, Block, 0);
      Comp.Process(@Buf[0], Block, @Side[0]);
    end;
    Free_:=Db(Buf[High(Buf)]);
    Check((Abs(Ducked - (-10 - 18)) < 0.01) AND (Abs(Free_ - (-10)) < 0.01),
      Format('sidechain: the detector follows the sidechain only (%.2f dB with a -10 dB sidechain, %.2f dB without)', [Ducked, Free_]));
  finally
    Comp.Free;
  end;
end;

// Reference true peak: 16x windowed-sinc interpolation with a long kernel.
function TruePeak16(const ABuf: TArray<Single>; AFirst, ALast: Integer): Double;
const
  Over = 16;
  Half = 64;
var
  N, P, K, Idx: Integer;
  T, X, W, Y: Double;
begin
  Result:=0;
  for N:=AFirst to ALast do
    for P:=0 to Over - 1 do
    begin
      Y:=0;
      for K:=-Half + 1 to Half do
      begin
        Idx:=N + K;
        if (Idx < 0) OR (Idx * 2 >= Length(ABuf)) then
          Continue;
        T:=K - P / Over;
        if Abs(T) < 1E-12 then
          X:=1
        else
          X:=Sin(Pi * T) / (Pi * T);
        W:=0.5 + 0.5 * Cos(Pi * T / Half);
        Y:=Y + ABuf[Idx * 2] * X * W;
      end;
      Result:=Max(Result, Abs(Y));
    end;
end;

procedure TestLimiterTransparent;
var
  Lim: TAudioLimiter;
  Input, Buf: TArray<Single>;
  I, L, N: Integer;
  MaxErr: Double;
begin
  Lim:=TAudioLimiter.Create;
  try
    Lim.Prepare(Fs, 2);
    Lim.CeilingDb:=-1;
    L:=Lim.Latency;
    N:=Fs;
    SetLength(Input, N * 2);
    for I:=0 to N - 1 do
    begin
      Input[I * 2]:=0.25 * Sin(2 * Pi * 1000 * I / Fs) + 0.25 * Sin(2 * Pi * 3000 * I / Fs + 1);
      Input[I * 2 + 1]:=-Input[I * 2];
    end;
    Buf:=Copy(Input);
    I:=0;
    while I < N do
    begin
      Lim.Process(@Buf[I * 2], Min(Block, N - I));
      Inc(I, Block);
    end;
    MaxErr:=0;
    for I:=L to N - 1 do
      MaxErr:=Max(MaxErr, Max(Abs(Buf[I * 2] - Input[(I - L) * 2]), Abs(Buf[I * 2 + 1] - Input[(I - L) * 2 + 1])));
    Check((MaxErr < 1E-7) AND (Lim.MaxReductionDb = 0) AND (L = 72 - 1 + AudioTruePeakFilterTaps DIV 2),
      Format('limiter below the ceiling: output = input delayed by Latency (%d frames) exactly (max error %.1e)', [L, MaxErr]));
  finally
    Lim.Free;
  end;
end;

procedure TestLimiterCeiling;
var
  Lim: TAudioLimiter;
  Buf: TArray<Single>;
  I, Pos, N, Len: Integer;
  Peak, Ceiling: Double;
begin
  RandSeed:=1770;
  Lim:=TAudioLimiter.Create;
  try
    Lim.Prepare(Fs, 2);
    Lim.CeilingDb:=-1;
    Lim.TruePeak:=False;
    Ceiling:=Lin(-1);
    N:=10 * Fs;
    SetLength(Buf, N * 2);
    for I:=0 to N * 2 - 1 do
      // Noise up to +11 dB (3.55) over the ceiling, with louder bursts.
      Buf[I]:=(Random * 2 - 1) * 3.0 * IfThen((I DIV 9600) MOD 3 = 0, 1.2, 0.3);
    Pos:=0;
    while Pos < N do
    begin
      Len:=Min(1 + Random(1000), N - Pos);
      Lim.Process(@Buf[Pos * 2], Len);
      Inc(Pos, Len);
    end;
    Peak:=0;
    for I:=0 to N * 2 - 1 do
      Peak:=Max(Peak, Abs(Buf[I]));
    Check(Peak <= Ceiling * (1 + 1E-6), Format('limiter, sample peak: 10 s of noise up to +12 dB over -1 dBFS in blocks of 1..1000 frames ' +
      '-> peak %.4f dBFS, reduction down to %.1f dB', [Db(Peak), Lim.MaxReductionDb]));
  finally
    Lim.Free;
  end;
end;

procedure TestLimiterTruePeak;
var
  Lim: TAudioLimiter;
  Buf: TArray<Single>;
  I, N, F: Integer;
  TP, Worst: Double;
  Freqs: array[0..4] of Double;
  TruePeakOn: Boolean;
begin
  // A quarter-rate sine at 45 degrees: samples at -3 dB, true peak at 0 dB.
  for TruePeakOn:=False to True do
  begin
    Lim:=TAudioLimiter.Create;
    try
      Lim.Prepare(Fs, 2);
      Lim.CeilingDb:=-1;
      Lim.TruePeak:=TruePeakOn;
      N:=Fs DIV 4;
      SetLength(Buf, N * 2);
      for I:=0 to N - 1 do
      begin
        Buf[I * 2]:=Sin(Pi / 2 * I + Pi / 4);
        Buf[I * 2 + 1]:=Buf[I * 2];
      end;
      Lim.Process(@Buf[0], N);
      TP:=TruePeak16(Buf, N DIV 2, N - 200);
      if TruePeakOn then
        Check(Db(TP) <= -1 + 0.25, Format('true-peak limiter on a quarter-rate sine (0 dBTP, -3 dB samples): %.2f dBTP (ceiling -1)', [Db(TP)]))
      else
        Check(Db(TP) > -0.1, Format('sample-peak limiter lets the same sine through at %.2f dBTP (why TruePeak is the default)', [Db(TP)]));
    finally
      Lim.Free;
    end;
  end;
  // High frequencies at random phases, 6 dB over the ceiling.
  Freqs[0]:=5000; Freqs[1]:=9000; Freqs[2]:=12000; Freqs[3]:=15000; Freqs[4]:=18000;
  Worst:=-99;
  RandSeed:=4;
  for F:=0 to High(Freqs) do
  begin
    Lim:=TAudioLimiter.Create;
    try
      Lim.Prepare(Fs, 2);
      Lim.CeilingDb:=-1;
      N:=Fs DIV 4;
      FillSine(Buf, 0, N, Freqs[F], Lin(5), Random * 2 * Pi);
      Lim.Process(@Buf[0], N);
      TP:=TruePeak16(Buf, N DIV 2, N - 200);
      Worst:=Max(Worst, Db(TP));
    finally
      Lim.Free;
    end;
  end;
  Check(Worst <= -1 + 0.5, Format('true-peak limiter, 5..18 kHz sines 6 dB over: worst %.2f dBTP (ceiling -1, 4x detector)', [Worst]));
end;

procedure TestLimiterRelease;
var
  Lim: TAudioLimiter;
  Buf: TArray<Single>;
  I: Integer;
  During, After: Double;
begin
  Lim:=TAudioLimiter.Create;
  try
    Lim.Prepare(Fs, 2);
    Lim.CeilingDb:=-1;
    Lim.ReleaseMs:=60;
    for I:=0 to 9 do
    begin
      FillSine(Buf, Int64(I) * Block, Block, 440, Lin(9), 0);
      Lim.Process(@Buf[0], Block);
    end;
    During:=Lim.ReductionDb;
    for I:=10 to 10 + 60 do
    begin
      FillSine(Buf, Int64(I) * Block, Block, 440, Lin(-20), 0);
      Lim.Process(@Buf[0], Block);
    end;
    After:=Lim.ReductionDb;
    Check((During < -9) AND (After > -0.05), Format('limiter release 60 ms: %.2f dB on a +9 dB burst, %.3f dB 600 ms later', [During, After]));
  finally
    Lim.Free;
  end;
end;

procedure TestMixerAlignment;
var
  Mixer: TAudioMixer;
  A, B: TAudioMixerInput;
  Buf: TArray<Single>;
  I, K, N: Integer;
  MaxSum: Double;
  P: PSingle;
begin
  Mixer:=TAudioMixer.Create(Fs, 2, 1);
  try
    A:=Mixer.AddInput('limited');
    B:=Mixer.AddInput('plain, inverted');
    A.AddFilter(TAudioLimiter.Create('limiter'));
    N:=Fs DIV 2;
    FillSine(Buf, 0, N, 997, 0.25, 0);
    A.Write(@Buf[0], N, 2, 0);
    for I:=0 to High(Buf) do
      Buf[I]:=-Buf[I];
    B.Write(@Buf[0], N, 2, 0);
    MaxSum:=0;
    I:=0;
    while I + Block + Mixer.Latency <= N do
    begin
      Mixer.Mix(I, Block);
      P:=Mixer.BusData[0];
      // The first Latency frames of a new chain are silence (it starts reading ahead): skip block 0.
      if I > 0 then
        for K:=0 to Block * 2 - 1 do
        MaxSum:=Max(MaxSum, Abs(PSingle(PByte(P) + K * SizeOf(Single))^));
      Inc(I, Block);
    end;
    Check((Mixer.Latency = A.Latency) AND (A.Latency > 0) AND (MaxSum < 1E-6), Format('mixer: a limited input (latency %d) and an ' +
      'inverted unfiltered copy cancel in the mix (max %.1e): latency is compensated', [Mixer.Latency, MaxSum]));
  finally
    Mixer.Free;
  end;
end;

procedure TestMixerSidechain;
var
  Mixer: TAudioMixer;
  Music, Voice, Other: TAudioMixerInput;
  Comp: TAudioCompressor;
  Buf: TArray<Single>;
  Pos: Int64;
  Ducked, Undocked, MutedLevel: Double;
  Raised: Boolean;

  procedure Run(ABlocks: Integer; AVoice: Boolean);
  var
    K: Integer;
  begin
    for K:=1 to ABlocks do
    begin
      FillConst(Buf, Block, Lin(-10));
      Music.Write(@Buf[0], Block, 2, Pos);
      FillConst(Buf, Block, IfThen(AVoice, Lin(-10), 0));
      Voice.Write(@Buf[0], Block, 2, Pos);
      Mixer.Mix(Pos, Block);
      Inc(Pos, Block);
    end;
  end;

begin
  Mixer:=TAudioMixer.Create(Fs, 2, 2);
  try
    Music:=Mixer.AddInput('music');
    Voice:=Mixer.AddInput('voice');
    Voice.BusMask:=2;
    Comp:=TAudioCompressor.Create('ducker');
    Comp.ThresholdDb:=-30;
    Comp.Ratio:=10;
    Comp.AttackMs:=1;
    Comp.ReleaseMs:=50;
    Music.AddFilter(Comp, Voice);
    Pos:=0;
    Run(50, True);
    Ducked:=Db(Mixer.BusData[0]^);
    Run(50, False);
    Undocked:=Db(Mixer.BusData[0]^);
    Voice.Muted:=True;
    Run(50, True);
    MutedLevel:=Db(Mixer.BusData[0]^);
    Check((Abs(Ducked - (-28)) < 0.01) AND (Abs(Undocked - (-10)) < 0.01) AND (Abs(MutedLevel - (-10)) < 0.01),
      Format('mixer sidechain: music ducked to %.2f dB while the voice talks, %.2f dB when it stops, %.2f dB while the voice is muted',
      [Ducked, Undocked, MutedLevel]));

    Raised:=False;
    try
      Voice.AddFilter(TAudioCompressor.Create, Music);
    except
      on E: EArgumentException do
        Raised:=True;
    end;
    Check(Raised AND (Voice.FilterCount = 0), 'a sidechain that would close a loop is rejected');
    Raised:=False;
    try
      Music.AddFilter(TAudioCompressor.Create, Music);
    except
      on E: EArgumentException do
        Raised:=True;
    end;
    Check(Raised, 'an input cannot be its own sidechain');

    Other:=Mixer.AddInput('other');
    Mixer.RemoveInput(Voice);
    FillConst(Buf, Block, Lin(-10));
    Music.Write(@Buf[0], Block, 2, Pos);
    Mixer.Mix(Pos, Block);
    Check((Music.Sidechains[0] = nil) AND (Mixer.InputCount = 2) AND (Other <> nil),
      'removing the sidechain input detaches it from the filter; the mix goes on');
  finally
    Mixer.Free;
  end;
end;

procedure TestGain;
var
  G: TAudioGainFilter;
  Buf: TArray<Single>;
begin
  G:=TAudioGainFilter.Create;
  try
    G.Prepare(Fs, 2);
    G.GainDb:=-6;
    FillConst(Buf, Block, 0.5);
    G.Process(@Buf[0], Block);
    FillConst(Buf, Block, 0.5);
    G.Process(@Buf[0], Block);
    Check(Abs(Db(Buf[0]) - (Db(0.5) - 6)) < 1E-4, Format('gain filter -6 dB: %.4f dB', [Db(Buf[0]) - Db(0.5)]));
  finally
    G.Free;
  end;
end;

begin
  try
    TestCompressorStatic;
    TestCompressorSine;
    TestCompressorTiming;
    TestCompressorSidechain;
    TestLimiterTransparent;
    TestLimiterCeiling;
    TestLimiterTruePeak;
    TestLimiterRelease;
    TestGain;
    TestMixerAlignment;
    TestMixerSidechain;
  except
    on E: Exception do
      Check(False, 'unexpected ' + E.ClassName + ': ' + E.Message);
  end;
  Writeln(Format('AudioDynamicsSmoke: %d passed, %d failed', [PassCount, FailCount]));
  if FailCount > 0 then
    ExitCode:=1;
end.
