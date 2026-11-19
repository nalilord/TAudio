program AudioClockSyncSmoke;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$APPTYPE CONSOLE}

{
  TAudioClockSync against a simulated capture device whose true sample clock is
  known: rate Fs * (1 + ppm(t)), optional slow wander, packets of 10 ms with
  jittered timestamps, stalls and flagged timestamp glitches.

  "True error" at an output frame = true capture time of the input sample it is
  read from minus the frame's reference time. It includes the jitter of the very
  first timestamp, which fixes the origin.

  Usage: AudioClockSyncSmoke [--quick]   (--quick: 10 min instead of 8 h)
}

uses
  SysUtils, Math,
  TAudio.ClockSync;

const
  Fs = 48000;
  PacketFrames = 480;
  T0Us = 1E9;

var
  Passed: Integer = 0;
  Failed: Integer = 0;
  Quick: Boolean = False;

procedure Check(Value: Boolean; const Text: string);
begin
  if Value then
  begin
    Inc(Passed);
    Writeln('PASS ', Text);
  end else
  begin
    Inc(Failed);
    Writeln('FAIL ', Text);
  end;
end;

type
  TScenario = record
    Name: string;
    Seconds: Double;
    Ppm: Double;
    WanderPpm: Double;
    WanderPeriodS: Double;
    JitterUs: Double;
    StallAtS, StallMs: Double;
    GlitchAtS, GlitchMs: Double;
    // Timestamps from a frame clock: they lag the true capture time by an amount that
    // grows at SawPpm and snaps back by SawStepUs once it reaches it (seen on a
    // Sound Blaster G3: 12.6 ppm, 1 ms USB frames).
    SawPpm, SawStepUs: Double;
    MaxCorrectionPpm: Double;
    Dsp: Boolean;
  end;

  TResult = record
    MaxAbsErrorUs: Double;
    FinalErrorUs: Double;
    FinalDriftPpm, TrueFinalPpm: Double;
    Stats: TAudioClockSyncStats;
    SnrDb: Double;
    OutputSeconds: Double;
    ElapsedS: Double;
  end;

function Scenario(const AName: string; ASeconds, APpm: Double): TScenario;
begin
  Result:=Default(TScenario);
  Result.Name:=AName;
  Result.Seconds:=ASeconds;
  Result.Ppm:=APpm;
  Result.JitterUs:=500;
  Result.StallAtS:=-1;
  Result.GlitchAtS:=-1;
  Result.MaxCorrectionPpm:=2000;
end;

var
  RandState: UInt32 = 12345;

function Rand01: Double;
begin
  RandState:=RandState * 1664525 + 1013904223;
  Result:=RandState / 4294967296.0;
end;

function Run(const S: TScenario): TResult;
var
  Sync: TAudioClockSync;
  // True start time (us, relative to T0) of every device packet.
  PacketT: array of Double;
  PacketCount, P, I, Produced, K0: Integer;
  TTrue, Ppm, Rate, Reported, Pos, Frac, TRead, TOut, Err, Origin: Double;
  Index: Int64;
  Input: TArray<Single>;
  Output: TArray<Single>;
  Stalled, Valid: Boolean;
  SigSum, ResSum, A, B, Saa, Sbb, Sab, Sya, Syb, Det, Ca, Cb, Y, W: Double;
  Block, N: Integer;
  Started: TDateTime;
  OutK: Int64;
  LostFrames: Int64;
  Saw: Double;
begin
  Result:=Default(TResult);
  Started:=Now;
  RandState:=12345;
  Sync:=TAudioClockSync.Create(1, Fs, NOT S.Dsp);
  try
    Sync.MaxCorrectionPpm:=S.MaxCorrectionPpm;
    PacketCount:=Ceil(S.Seconds * Fs / PacketFrames) + 2;
    SetLength(PacketT, PacketCount + 1);
    SetLength(Input, PacketFrames);
    Output:=nil;
    TTrue:=0;
    Origin:=0;
    LostFrames:=0;
    Ppm:=S.Ppm;
    SigSum:=0;
    ResSum:=0;
    for P:=0 to PacketCount - 1 do
    begin
      PacketT[P]:=TTrue;
      Ppm:=S.Ppm;
      if S.WanderPpm <> 0 then
        Ppm:=Ppm + S.WanderPpm * Sin(2 * Pi * TTrue / (S.WanderPeriodS * 1E6));
      Rate:=Fs * (1 + Ppm * 1E-6);
      if S.Dsp then
        for I:=0 to PacketFrames - 1 do
          Input[I]:=0.5 * Sin(2 * Pi * 997 * (TTrue + I * 1E6 / Rate) / 1E6);
      Stalled:=(S.StallAtS >= 0) AND (TTrue >= S.StallAtS * 1E6) AND (TTrue < S.StallAtS * 1E6 + S.StallMs * 1000);
      Reported:=T0Us + TTrue + (Rand01 * 2 - 1) * S.JitterUs;
      if S.SawStepUs > 0 then
      begin
        Saw:=TTrue * S.SawPpm * 1E-6;
        Reported:=Reported - (Saw - S.SawStepUs * Floor(Saw / S.SawStepUs));
      end;
      Valid:=True;
      if (S.GlitchAtS >= 0) AND (P = Round(S.GlitchAtS * Fs / PacketFrames)) then
      begin
        Reported:=Reported + S.GlitchMs * 1000;
        Valid:=False;
      end;
      if P = 0 then
        Origin:=Reported - T0Us;
      TTrue:=TTrue + PacketFrames * 1E6 / Rate;
      PacketT[P + 1]:=TTrue;
      if Stalled then
      begin
        Inc(LostFrames, PacketFrames);
        Continue;
      end;
      Produced:=Sync.Push(@Input[0], PacketFrames, Round(Reported), Output, 0, Valid);

      // True alignment of the next output frame. Input positions count bridged silence;
      // map them back to device frames with the real number of lost frames.
      Pos:=Sync.NextInputPosition + LostFrames - Sync.Stats.SilenceInputFrames;
      if Pos >= 0 then
      begin
        Index:=Trunc(Pos / PacketFrames);
        if Index <= P then
        begin
          Frac:=(Pos - Index * PacketFrames) / PacketFrames;
          TRead:=PacketT[Index] + Frac * (PacketT[Index + 1] - PacketT[Index]);
          OutK:=Sync.NextOutputFrame;
          TOut:=Origin + OutK * 1E6 / Fs;
          Err:=TRead - TOut;
          Result.FinalErrorUs:=Err;
          if TTrue > 10E6 then
            Result.MaxAbsErrorUs:=Max(Result.MaxAbsErrorUs, Abs(Err));
        end;
      end;

      // DSP quality: fit a sine at the nominal-rate frequency per output block.
      if S.Dsp AND (Produced >= 64) AND (TTrue > 5E6) then
      begin
        OutK:=Sync.NextOutputFrame - Produced;
        Saa:=0; Sbb:=0; Sab:=0; Sya:=0; Syb:=0;
        for I:=0 to Produced - 1 do
        begin
          W:=2 * Pi * 997 * (OutK + I) / Fs;
          A:=Sin(W);
          B:=Cos(W);
          Y:=Output[I];
          Saa:=Saa + A * A; Sbb:=Sbb + B * B; Sab:=Sab + A * B;
          Sya:=Sya + Y * A; Syb:=Syb + Y * B;
        end;
        Det:=Saa * Sbb - Sab * Sab;
        if Det > 0 then
        begin
          Ca:=(Sya * Sbb - Syb * Sab) / Det;
          Cb:=(Syb * Saa - Sya * Sab) / Det;
          for I:=0 to Produced - 1 do
          begin
            W:=2 * Pi * 997 * (OutK + I) / Fs;
            Y:=Ca * Sin(W) + Cb * Cos(W);
            SigSum:=SigSum + Y * Y;
            ResSum:=ResSum + Sqr(Output[I] - Y);
          end;
        end;
      end;
    end;
    Result.Stats:=Sync.Stats;
    Result.FinalDriftPpm:=Result.Stats.DriftPpm;
    Result.TrueFinalPpm:=Ppm;
    Result.OutputSeconds:=Result.Stats.OutputFrames / Fs;
    if ResSum > 0 then
      Result.SnrDb:=10 * Log10(SigSum / ResSum)
    else
      Result.SnrDb:=999;
  finally
    Sync.Free;
  end;
  Result.ElapsedS:=(Now - Started) * 86400;
  Writeln(Format('INFO %-22s %7.0f s: drift est %9.3f ppm (true %9.3f), max |err| %7.1f us, final err %7.1f us, ' +
    'correction %8.2f ppm, resyncs %d, skipped %d, silence in %d out %d, SNR %.1f dB, %.1f s CPU',
    [S.Name, S.Seconds, Result.FinalDriftPpm, Result.TrueFinalPpm, Result.MaxAbsErrorUs, Result.FinalErrorUs,
    Result.Stats.CorrectionPpm, Result.Stats.Resyncs, Result.Stats.SkippedFrames, Result.Stats.SilenceInputFrames,
    Result.Stats.SilenceOutputFrames, Result.SnrDb, Result.ElapsedS]));
end;

procedure Steady(APpm: Double);
var
  S: TScenario;
  R: TResult;
begin
  S:=Scenario(Format('steady %.0f ppm', [APpm]), 3600, APpm);
  if Quick then
    S.Seconds:=600;
  R:=Run(S);
  // Tight on purpose: a precision bug once grew the error to ~0.6 ms per hour and passed a 1 ms bound.
  Check(R.MaxAbsErrorUs < 250, Format('%s: aligned within 250 us after 10 s (max %.1f us)', [S.Name, R.MaxAbsErrorUs]));
  Check(Abs(R.FinalDriftPpm - APpm) < 1, Format('%s: drift estimated within 1 ppm (%.3f)', [S.Name, R.FinalDriftPpm]));
  Check((R.Stats.Resyncs = 0) AND (R.Stats.SkippedFrames = 0) AND (R.Stats.SilenceInputFrames = 0) AND
    (R.Stats.SilenceOutputFrames = 0), Format('%s: no samples dropped or invented (resyncs %d)', [S.Name, R.Stats.Resyncs]));
end;

var
  S: TScenario;
  R: TResult;
begin
  Quick:=(ParamCount >= 1) AND (ParamStr(1) = '--quick');
  try
    Steady(0);
    Steady(100);
    Steady(-100);
    Steady(500);
    Steady(-1500);

    // Long run: slow temperature wander around +80 ppm, the E07 exit horizon.
    S:=Scenario('8 h wander', 8 * 3600, 80);
    if Quick then
      S.Seconds:=600;
    S.WanderPpm:=20;
    S.WanderPeriodS:=3600;
    R:=Run(S);
    Check(R.MaxAbsErrorUs < 250, Format('%s: aligned within 250 us (max %.1f us; exit allows one video frame, 16.7 ms)',
      [S.Name, R.MaxAbsErrorUs]));
    Check(R.Stats.Resyncs = 0, Format('%s: no resyncs (%d)', [S.Name, R.Stats.Resyncs]));

    // Real samples: a 997 Hz tone captured at +300 ppm must come out clean at the nominal rate.
    // The floor is ~90 dB (filter passband ripple); ratio updates driven by timestamp jitter
    // frequency-modulate the tone slightly, so the bound depends on the jitter.
    S:=Scenario('dsp +300 ppm, 50 us', 60, 300);
    S.Dsp:=True;
    S.JitterUs:=50;
    R:=Run(S);
    Check(R.SnrDb > 85, Format('%s: resampled tone SNR %.1f dB > 85 dB', [S.Name, R.SnrDb]));
    S:=Scenario('dsp +300 ppm', 60, 300);
    S.Dsp:=True;
    R:=Run(S);
    Check(R.SnrDb > 75, Format('%s: resampled tone SNR %.1f dB > 75 dB with 500 us jitter', [S.Name, R.SnrDb]));
    Check(R.MaxAbsErrorUs < 1000, Format('%s: aligned within 1 ms (max %.1f us)', [S.Name, R.MaxAbsErrorUs]));
    Check(Abs(R.OutputSeconds - 60) < 0.05, Format('%s: output length %.3f s for 60 s of reference time', [S.Name, R.OutputSeconds]));

    // Device stall: 200 ms of packets lost, then correct timestamps again.
    S:=Scenario('stall 200 ms', 120, 100);
    S.StallAtS:=30;
    S.StallMs:=200;
    R:=Run(S);
    Check(R.Stats.Resyncs = 1, Format('%s: one resync (%d)', [S.Name, R.Stats.Resyncs]));
    Check(Abs(R.Stats.SilenceInputFrames - 9600) <= PacketFrames,
      Format('%s: gap bridged with %d frames of silence (200 ms = 9600)', [S.Name, R.Stats.SilenceInputFrames]));
    Check(Abs(R.FinalErrorUs) < 1000, Format('%s: aligned again (final %.1f us)', [S.Name, R.FinalErrorUs]));

    // Flagged timestamp glitch: +80 ms on one packet must not be mistaken for a gap.
    S:=Scenario('flagged glitch', 60, -50);
    S.GlitchAtS:=20;
    S.GlitchMs:=80;
    R:=Run(S);
    Check((R.Stats.Resyncs = 0) AND (R.MaxAbsErrorUs < 1000), Format('%s: ignored (resyncs %d, max %.1f us)',
      [S.Name, R.Stats.Resyncs, R.MaxAbsErrorUs]));

    // Frame-quantised timestamps (G3 on Creative's driver): the true rate shows only in 1 ms
    // catch-up steps every ~80 s; a short fit window that misses them under-corrects.
    S:=Scenario('frame-clock sawtooth', 2 * 3600, 14.4);
    if Quick then
      S.Seconds:=1800;
    S.JitterUs:=50;
    S.SawPpm:=12.6;
    S.SawStepUs:=1000;
    R:=Run(S);
    // The 30 s fit reads ~0 ppm between steps and ~+45 ppm across one; only the bound matters.
    Check(Abs(R.FinalDriftPpm - 14.4) < 40, Format('%s: rate estimate within the sawtooth swing (%.2f ppm, true 14.4)', [S.Name,
      R.FinalDriftPpm]));
    Check((R.MaxAbsErrorUs < 1500) AND (R.Stats.Resyncs = 0),
      Format('%s: bounded by the sawtooth, no residual drift (max %.1f us, final %.1f us)', [S.Name, R.MaxAbsErrorUs, R.FinalErrorUs]));

    // Out of range: a device 5000 ppm fast with corrections capped at 2000 ppm cannot be
    // followed smoothly; the error must stay bounded by counted resyncs.
    S:=Scenario('beyond the cap', 120, 5000);
    R:=Run(S);
    Check((R.Stats.Resyncs > 0) AND (Abs(R.FinalErrorUs) < 45000),
      Format('%s: bounded by %d counted resyncs (final %.1f us)', [S.Name, R.Stats.Resyncs, R.FinalErrorUs]));
  except
    on E: Exception do
      Check(False, 'unexpected ' + E.ClassName + ': ' + E.Message);
  end;
  Writeln(Format('AudioClockSyncSmoke: %d passed, %d failed', [Passed, Failed]));
  if Failed > 0 then
    ExitCode:=1;
end.
