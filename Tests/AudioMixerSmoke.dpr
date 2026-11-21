program AudioMixerSmoke;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$APPTYPE CONSOLE}

{
  TAudio.Meter and TAudio.Mixer (PasAV StudioPlan S01).

  Meter: the K-weighting stages against the BS.1770 coefficients at 48 kHz, the
  EBU Tech 3341 reference levels (1 kHz sine at -23 dBFS reads -23.0 LUFS), sample
  peak, RMS, and both integrated-loudness gates.
  Mixer: exact sums, gain in dB, mute, bus masks, balance, timeline alignment
  across different chunking, gaps, late and early data, overlaps, mono inputs, a
  click-free gain change, clipping, and concurrent writers.
}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math,
  TAudio.Meter, TAudio.Mixer;

const
  Fs = 48000;

var
  Passed: Integer = 0;
  Failed: Integer = 0;

procedure Check(ACondition: Boolean; const AText: string);
begin
  if ACondition then
  begin
    Inc(Passed);
    Writeln('PASS ', AText);
  end else
  begin
    Inc(Failed);
    Writeln('FAIL ', AText);
  end;
end;

function Near(A, B, ATolerance: Double): Boolean;
begin
  Result:=Abs(A - B) <= ATolerance;
end;

// Interleaved stereo sine; ALeft/ARight amplitudes.
procedure FeedSine(AMeter: TAudioMeter; ASeconds, AFreq, ALeft, ARight: Double);
const
  Chunk = 480;
var
  Buf: array of Single;
  Total, Done, N, I: Integer;
begin
  SetLength(Buf, Chunk * 2);
  Total:=Round(ASeconds * Fs);
  Done:=0;
  while Done < Total do
  begin
    N:=Min(Chunk, Total - Done);
    for I:=0 to N - 1 do
    begin
      Buf[2 * I]:=ALeft * Sin(2 * Pi * AFreq * (Done + I) / Fs);
      Buf[2 * I + 1]:=ARight * Sin(2 * Pi * AFreq * (Done + I) / Fs);
    end;
    AMeter.Process(@Buf[0], N);
    Inc(Done, N);
  end;
end;

procedure TestMeter;
var
  M: TAudioMeter;
  A: Double;
begin
  M:=TAudioMeter.Create(Fs, 2);
  try
    // BS.1770-4 table 1 and 2 (48 kHz).
    Check(Near(M.KShelf.B0, 1.53512485958697, 1E-8) AND Near(M.KShelf.B1, -2.69169618940638, 1E-8) AND
      Near(M.KShelf.B2, 1.19839281085285, 1E-8) AND Near(M.KShelf.A1, -1.69065929318241, 1E-8) AND
      Near(M.KShelf.A2, 0.73248077421585, 1E-8), 'K-weighting shelf matches BS.1770 at 48 kHz');
    Check(Near(M.KHighPass.A1, -1.99004745483398, 1E-8) AND Near(M.KHighPass.A2, 0.99007225036621, 1E-8),
      'K-weighting high-pass matches BS.1770 at 48 kHz');

    // EBU Tech 3341 case 1: stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS (+/-0.1).
    A:=Power(10, -23 / 20);
    FeedSine(M, 20, 1000, A, A);
    Check(Near(M.Momentary, -23, 0.1) AND Near(M.ShortTerm, -23, 0.1) AND Near(M.Integrated, -23, 0.1),
      Format('-23 dBFS stereo sine: momentary %.2f, short-term %.2f, integrated %.2f LUFS', [M.Momentary, M.ShortTerm, M.Integrated]));
    Check(Near(M.PeakDb[0], -23, 0.01) AND Near(M.RmsDb[1], -26.01, 0.02), Format('sample peak %.2f dBFS, RMS %.2f dBFS',
      [M.PeakDb[0], M.RmsDb[1]]));
    Check(M.ClippedSamples = 0, 'no clipping below full scale');

    // The same sine in one channel: 3 dB less.
    M.Reset;
    FeedSine(M, 10, 1000, A, 0);
    Check(Near(M.Integrated, -26.01, 0.1), Format('one channel: %.2f LUFS (-26.0)', [M.Integrated]));
    Check(IsInfinite(M.PeakDb[1]) AND (M.PeakDb[1] < 0), 'silent channel peaks at -inf');

    // Absolute gate: silence does not pull integrated loudness down.
    M.Reset;
    FeedSine(M, 10, 1000, A, A);
    FeedSine(M, 10, 1000, 0, 0);
    Check(Near(M.Integrated, -23, 0.1) AND IsInfinite(M.Momentary), Format('silence gated out: integrated %.2f, momentary %.1f',
      [M.Integrated, M.Momentary]));

    // Relative gate: 20 s at -36 then 20 s at -23 integrate to -23 (the quiet part is > 10 LU below).
    M.Reset;
    FeedSine(M, 20, 1000, Power(10, -36 / 20), Power(10, -36 / 20));
    FeedSine(M, 20, 1000, A, A);
    Check(Near(M.Integrated, -23, 0.15), Format('relative gate: %.2f LUFS (-23)', [M.Integrated]));

    // Full scale clips.
    M.Reset;
    FeedSine(M, 1, 1000, 1.2, 0);
    Check(M.ClippedSamples > 0, Format('over full scale counted (%d samples)', [M.ClippedSamples]));
  finally
    M.Free;
  end;
end;

// Writes AFrames of a constant (stereo) value.
procedure WriteConst(AInput: TAudioMixerInput; AStart: Int64; AFrames: Integer; AValue: Single; AChannels: Integer = 2);
var
  Buf: array of Single;
  I: Integer;
begin
  SetLength(Buf, AFrames * AChannels);
  for I:=0 to High(Buf) do
    Buf[I]:=AValue;
  AInput.Write(@Buf[0], AFrames, AChannels, AStart);
end;

function BusSample(AMixer: TAudioMixer; ABus, AFrame, AChannel: Integer): Single;
begin
  Result:=PSingle(PByte(AMixer.BusData[ABus]) + (AFrame * AMixer.Channels + AChannel) * SizeOf(Single))^;
end;

procedure TestMixer;
var
  M: TAudioMixer;
  A, B: TAudioMixerInput;
  Buf: array of Single;
  I, Impulse: Integer;
  OK: Boolean;
  Prev, V: Double;
begin
  M:=TAudioMixer.Create(Fs, 2, 2, 1000);
  try
    A:=M.AddInput('A');
    B:=M.AddInput('B');
    B.GainDb:=-6.0206;
    WriteConst(A, 0, 480, 0.25);
    WriteConst(B, 0, 480, 0.25);
    M.Mix(0, 480);
    Check(Near(BusSample(M, 0, 100, 0), 0.375, 1E-5) AND Near(BusSample(M, 0, 479, 1), 0.375, 1E-5),
      Format('0 dB + -6 dB: %.5f (0.375)', [BusSample(M, 0, 100, 0)]));

    B.Muted:=True;
    WriteConst(A, 480, 480, 0.25);
    WriteConst(B, 480, 480, 0.25);
    M.Mix(480, 480);
    // The mute ramps over one block; the next block is exact.
    WriteConst(A, 960, 480, 0.25);
    WriteConst(B, 960, 480, 0.25);
    M.Mix(960, 480);
    Check(Near(BusSample(M, 0, 0, 0), 0.25, 1E-6) AND Near(BusSample(M, 0, 479, 0), 0.25, 1E-6), 'muted input leaves the mix');
    B.Muted:=False;


    // Bus masks: A on bus 0, B on bus 1 only.
    A.BusMask:=1;
    B.BusMask:=2;
    B.GainDb:=0;
    for I:=0 to 1 do
    begin
      WriteConst(A, 1440 + I * 480, 480, 0.25);
      WriteConst(B, 1440 + I * 480, 480, 0.5);
      M.Mix(1440 + I * 480, 480);
    end;
    Check(Near(BusSample(M, 0, 10, 0), 0.25, 1E-6) AND Near(BusSample(M, 1, 10, 0), 0.5, 1E-6), 'bus masks route each input');

    // Balance: centre is unity, hard left silences the right.
    A.Balance:=0;
    for I:=0 to 1 do
    begin
      WriteConst(A, 2400 + I * 480, 480, 0.25);
      WriteConst(B, 2400 + I * 480, 480, 0);
      M.Mix(2400 + I * 480, 480);
    end;
    Check(Near(BusSample(M, 0, 10, 0), 0.25, 1E-6) AND Near(BusSample(M, 0, 10, 1), 0, 1E-6),
      Format('balance 0: left %.4f, right %.4f', [BusSample(M, 0, 10, 0), BusSample(M, 0, 10, 1)]));
    A.Balance:=0.75;
    for I:=0 to 1 do
    begin
      WriteConst(A, 3360 + I * 480, 480, 0.25);
      WriteConst(B, 3360 + I * 480, 480, 0);
      M.Mix(3360 + I * 480, 480);
    end;
    Check(Near(BusSample(M, 0, 10, 1), 0.25, 1E-6) AND Near(BusSample(M, 0, 10, 0), 0.25 * Sqrt(2) * Cos(0.75 * Pi / 2), 1E-5),
      Format('balance 0.75 (constant power): left %.4f, right %.4f', [BusSample(M, 0, 10, 0), BusSample(M, 0, 10, 1)]));
    A.Balance:=0.5;
    A.BusMask:=1;
    B.BusMask:=1;
  finally
    M.Free;
  end;

  // Alignment: an impulse written in different chunking lands on the same frame.
  M:=TAudioMixer.Create(Fs, 2, 1, 1000);
  try
    A:=M.AddInput('A');
    B:=M.AddInput('B');
    SetLength(Buf, 960 * 2);
    for I:=0 to High(Buf) do
      Buf[I]:=0;
    Buf[300 * 2]:=0.5;
    A.Write(@Buf[0], 960, 2, 1000);
    Buf[300 * 2]:=0.25;
    for I:=0 to 9 do
      B.Write(@Buf[I * 96 * 2], 96, 2, 1000 + I * 96);
    M.Mix(1000, 960);
    Impulse:=-1;
    for I:=0 to 959 do
      if Near(BusSample(M, 0, I, 0), 0.75, 1E-6) then
        Impulse:=I;
    Check(Impulse = 300, Format('impulses written in 960- and 96-frame chunks coincide (frame %d)', [Impulse]));
  finally
    M.Free;
  end;

  // Gaps, late data, early overflow, overlap, mono, clipping.
  M:=TAudioMixer.Create(Fs, 2, 1, 100);
  try
    A:=M.AddInput('A');
    WriteConst(A, 0, 480, 0.25);
    WriteConst(A, 960, 480, 0.25);
    M.Mix(0, 480);
    M.Mix(480, 480);
    Check((A.GapFrames = 480) AND Near(BusSample(M, 0, 10, 0), 0, 1E-9), Format('480-frame gap becomes silence (%d)', [A.GapFrames]));
    M.Mix(960, 480);
    WriteConst(A, 500, 480, 0.25);
    Check(A.LateFrames = 480, Format('data for a mixed range is dropped (%d late)', [A.LateFrames]));
    WriteConst(A, 1440, 9600, 0.25);
    Check(A.OverflowFrames = 9600 - 4800, Format('only the 100 ms buffer is kept ahead (%d dropped)', [A.OverflowFrames]));
    WriteConst(A, 1440, 480, 0.75);
    Check(A.OverlapFrames = 480, 'a second copy of a buffered range is ignored');
    M.Mix(1440, 480);
    Check(Near(BusSample(M, 0, 10, 0), 0.25, 1E-6), 'the first copy wins');
    M.Mix(1920, 4800);
    M.Mix(6720, 480);
    Check(A.UnderrunFrames >= 480, Format('mixing past the data counts underruns (%d)', [A.UnderrunFrames]));

    WriteConst(A, 7200, 480, 0.4, 1);
    M.Mix(7200, 480);
    Check(Near(BusSample(M, 0, 10, 0), 0.4, 1E-6) AND Near(BusSample(M, 0, 10, 1), 0.4, 1E-6), 'mono input feeds both channels');

    B:=M.AddInput('B');
    WriteConst(A, 7680, 480, 0.8);
    WriteConst(B, 7680, 480, 0.8);
    M.Mix(7680, 480);
    Check((M.BusClippedSamples[0] = 960) AND Near(BusSample(M, 0, 10, 0), 1.6, 1E-5),
      Format('sum over full scale is kept and counted (%d samples, %.2f)', [M.BusClippedSamples[0], BusSample(M, 0, 10, 0)]));
  finally
    M.Free;
  end;

  // A gain change ramps over one block: no step larger than the ramp increment.
  M:=TAudioMixer.Create(Fs, 2, 1, 1000);
  try
    A:=M.AddInput('A');
    WriteConst(A, 0, 480, 0.5);
    M.Mix(0, 480);
    A.GainDb:=-20;
    WriteConst(A, 480, 480, 0.5);
    M.Mix(480, 480);
    OK:=True;
    Prev:=0.5;
    for I:=0 to 479 do
    begin
      V:=BusSample(M, 0, I, 0);
      if Abs(V - Prev) > 0.5 * 0.9 / 480 + 1E-6 then
        OK:=False;
      Prev:=V;
    end;
    Check(OK AND Near(Prev, 0.05, 1E-5), Format('gain change ramps linearly to %.4f with no step', [Prev]));
  finally
    M.Free;
  end;
end;

type
  TWriter = class(TThread)
  public
    Input: TAudioMixerInput;
    Frames: Integer;
    procedure Execute; override;
  end;

procedure TWriter.Execute;
var
  Pos: Int64;
  Buf: array[0..95] of Single;
  I: Integer;
begin
  for I:=0 to High(Buf) do
    Buf[I]:=0.1;
  Pos:=0;
  while (Pos < Frames) AND NOT Terminated do
  begin
    Input.Write(@Buf[0], 48, 2, Pos);
    Inc(Pos, 48);
    if Pos MOD 4800 = 0 then
      Sleep(1);
  end;
end;

// Active: an independent automation gate, ramped like mute, Muted untouched.
procedure TestActiveGate;
var
  M: TAudioMixer;
  A, B: TAudioMixerInput;
  I: Integer;
begin
  M:=TAudioMixer.Create(Fs, 2, 1, 1000);
  try
    A:=M.AddInput('A');
    B:=M.AddInput('B');
    B.Active:=False;
    for I:=0 to 1 do
    begin
      WriteConst(A, I * 480, 480, 0.25);
      WriteConst(B, I * 480, 480, 0.25);
      M.Mix(I * 480, 480);
    end;
    Check(Near(BusSample(M, 0, 0, 0), 0.25, 1E-6) AND Near(BusSample(M, 0, 479, 0), 0.25, 1E-6) AND NOT B.Muted,
      'an inactive input leaves the mix and stays unmuted');
    B.Active:=True;
    WriteConst(A, 960, 480, 0.25);
    WriteConst(B, 960, 480, 0.25);
    M.Mix(960, 480);
    Check((BusSample(M, 0, 0, 0) < BusSample(M, 0, 479, 0)) AND Near(BusSample(M, 0, 479, 0), 0.5, 1E-3),
      Format('reactivating ramps back in over one block (%.4f -> %.4f)', [BusSample(M, 0, 0, 0), BusSample(M, 0, 479, 0)]));
  finally
    M.Free;
  end;
end;

procedure TestThreads;
var
  M: TAudioMixer;
  W: array[0..3] of TWriter;
  I: Integer;
  Pos, Ready: Int64;
  Total, Underruns: Int64;
begin
  M:=TAudioMixer.Create(Fs, 2, 1, 2000);
  try
    for I:=0 to High(W) do
    begin
      W[I]:=TWriter.Create(True);
      W[I].Input:=M.AddInput(Format('W%d', [I]));
      W[I].Frames:=Fs * 2;
      W[I].Start;
    end;
    // Mix, 10 ms at a time, whatever every writer has delivered while they keep writing.
    Pos:=0;
    while Pos < Fs * 2 do
    begin
      Ready:=High(Int64);
      for I:=0 to High(W) do
        Ready:=Min(Ready, W[I].Input.FramesWritten);
      while Pos + 480 <= Ready do
      begin
        M.Mix(Pos, 480);
        Inc(Pos, 480);
      end;
      Sleep(1);
    end;
    Total:=0;
    Underruns:=0;
    for I:=0 to High(W) do
    begin
      W[I].WaitFor;
      Inc(Total, W[I].Input.FramesWritten);
      Inc(Underruns, W[I].Input.UnderrunFrames);
      W[I].Free;
    end;
    Check(Total = 4 * Fs * 2, Format('four writer threads delivered %d frames', [Total]));
    Check((Underruns = 0) AND Near(M.BusMeter[0].PeakDb[0], AudioLinearToDb(0.4), 0.01),
      Format('concurrent mix of everything delivered: peak %.2f dBFS (0.4), underruns %d', [M.BusMeter[0].PeakDb[0], Underruns]));
  finally
    M.Free;
  end;
end;

begin
  try
    TestMeter;
    TestMixer;
    TestActiveGate;
    TestThreads;
  except
    on E: Exception do
      Check(False, 'unexpected ' + E.ClassName + ': ' + E.Message);
  end;
  Writeln(Format('AudioMixerSmoke: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    ExitCode:=1;
end.
