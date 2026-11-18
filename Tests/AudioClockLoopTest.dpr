program AudioClockLoopTest;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$APPTYPE CONSOLE}
{$POINTERMATH ON}

{
  Long-run acoustic loop test for TAudioClockSync (PasAV HardwareEncodePlan E07.3).

  Device A plays a click every IntervalMs at exact positions on A's sample clock.
  A cable carries A's output into device B's input. Two captures run at once:
    A: loopback of A's render endpoint (A's clock)
    B: B's capture endpoint (B's clock)
  Each is locked to the QPC clock with TAudioClockSync, and every click's arrival
  time is measured in both by cross-correlation with the click template.

  The synced difference tB - tA is the analog path delay: it must stay constant.
  The same difference computed from raw device sample counts (no clock sync) is
  logged beside it and drifts by the devices' ppm difference.

    AudioClockLoopTest --list
    AudioClockLoopTest <seconds> <render A> <capture B> [csv-file]

  Devices are name substrings. Exit 1 if the synced difference moves by more than
  one video frame (16.7 ms), any device resyncs, or clicks go missing.
  With "--same <render A>" instead of a capture device, B is a second loopback of
  A (no cable needed): a self-check of the measurement chain.
}

uses
  SysUtils, Classes, SyncObjs, Math,
  TAudio.Types, TAudio.Clock, TAudio.Output, TAudio.Output.WASAPI, TAudio.Input, TAudio.Input.WASAPI, TAudio.ClockSync;

const
  IntervalMs = 1000;
  BurstMs = 2;
  BurstHz = 2000;
  TriggerLevel = 0.02;
  FrameUs = 16667;

type
  TClick = record
    SyncedUs: Double;
    RawUs: Double;
  end;

  // Finds click onsets in a mono stream with known per-sample times.
  TDetector = class
  private
    FRate: Integer;
    FTemplate: TArray<Double>;
    FHistory: TArray<Single>;
    FHistoryStart: Int64;     // sample index of FHistory[0]
    FCount: Int64;            // samples appended so far
    FPendingTrigger: Int64;   // sample index of a trigger waiting for its window, or -1
    FLastClick: Int64;
    function SampleAt(Index: Int64): Double;
  public
    Clicks: TArray<Double>;   // onset times, in the stream's sample index (fractional)
    Peak: Double;             // largest absolute sample seen, for level diagnostics
    constructor Create(Rate: Integer);
    procedure Append(Data: PSingle; Frames: Integer);
  end;

  TTrack = class
  public
    Name: string;
    Input: TAudioInputWASAPI;
    Sync: TAudioClockSync;
    Lock: TCriticalSection;
    Floats, Mono, Output: TArray<Single>;
    SyncedDetector, RawDetector: TDetector;
    FirstCaptureUs: Int64;
    SyncedFirstIndex: Int64;
    Discontinuities: Int64;
    Error: string;
    constructor Create;
    destructor Destroy; override;
    procedure HandleData(Sender: TObject; const Packet: TAudioInputPacket);
    procedure HandleError(Sender: TObject; const Message: string);
    function ClickTimes: TArray<TClick>;
    function Stats: TAudioClockSyncStats;
  end;

  TRenderThread = class(TThread)
  public
    Output: TAudioOutputWASAPI;
    Template: TArray<Single>;
    Accepted, Offered: Int64;
    procedure Execute; override;
  end;

{ TDetector }

constructor TDetector.Create(Rate: Integer);
var
  I, N: Integer;
begin
  FRate:=Rate;
  N:=Rate * BurstMs DIV 1000;
  SetLength(FTemplate, N);
  for I:=0 to N - 1 do
    FTemplate[I]:=Sin(2 * Pi * BurstHz * I / Rate) * 0.5 * (1 - Cos(2 * Pi * I / (N - 1)));
  FPendingTrigger:=-1;
  FLastClick:=-Int64(Rate) * 10;
end;

function TDetector.SampleAt(Index: Int64): Double;
begin
  Result:=FHistory[Index - FHistoryStart];
end;

procedure TDetector.Append(Data: PSingle; Frames: Integer);
var
  I, Lag, BestLag, N, Keep, Drop: Integer;
  WindowStart: Int64;
  C, Best, Prev, Next, Denom, Offset: Double;
  K: Integer;
  Corr: array of Double;
begin
  N:=Length(FHistory);
  SetLength(FHistory, N + Frames);
  Move(Data^, FHistory[N], Frames * SizeOf(Single));
  for I:=0 to Frames - 1 do
    if Abs(Data[I]) > Peak then
      Peak:=Abs(Data[I]);
  for I:=0 to Frames - 1 do
    if (FPendingTrigger < 0) AND (Abs(Data[I]) > TriggerLevel) AND (FCount + I - FLastClick > FRate * IntervalMs DIV 2000) then
      FPendingTrigger:=FCount + I;
  Inc(FCount, Frames);

  // Correlate once the window [trigger - 3 ms, trigger + 3 ms + template] is complete.
  if (FPendingTrigger >= 0) AND (FCount >= FPendingTrigger + FRate * 3 DIV 1000 + Length(FTemplate) + 2) then
  begin
    WindowStart:=Max(FHistoryStart, FPendingTrigger - FRate * 3 DIV 1000);
    SetLength(Corr, FRate * 6 DIV 1000);
    Best:=-1;
    BestLag:=0;
    for Lag:=0 to High(Corr) do
    begin
      C:=0;
      for K:=0 to High(FTemplate) do
        C:=C + FTemplate[K] * SampleAt(WindowStart + Lag + K);
      // Analog paths may invert polarity.
      Corr[Lag]:=Abs(C);
      if Corr[Lag] > Best then
      begin
        Best:=Corr[Lag];
        BestLag:=Lag;
      end;
    end;
    Offset:=0;
    if (BestLag > 0) AND (BestLag < High(Corr)) then
    begin
      Prev:=Corr[BestLag - 1];
      Next:=Corr[BestLag + 1];
      Denom:=Prev - 2 * Best + Next;
      if Denom <> 0 then
        Offset:=0.5 * (Prev - Next) / Denom;
    end;
    SetLength(Clicks, Length(Clicks) + 1);
    Clicks[High(Clicks)]:=WindowStart + BestLag + Offset;
    FLastClick:=FPendingTrigger;
    FPendingTrigger:=-1;
  end;

  // Keep about a second of history.
  Keep:=FRate;
  if (FPendingTrigger < 0) AND (Length(FHistory) > 2 * Keep) then
  begin
    Drop:=Length(FHistory) - Keep;
    Move(FHistory[Drop], FHistory[0], Keep * SizeOf(Single));
    SetLength(FHistory, Keep);
    Inc(FHistoryStart, Drop);
  end;
end;

{ TTrack }

constructor TTrack.Create;
begin
  Lock:=TCriticalSection.Create;
  FirstCaptureUs:=-1;
  SyncedFirstIndex:=-1;
end;

destructor TTrack.Destroy;
begin
  Input.Free;
  Sync.Free;
  SyncedDetector.Free;
  RawDetector.Free;
  Lock.Free;
  inherited;
end;

procedure TTrack.HandleData(Sender: TObject; const Packet: TAudioInputPacket);
var
  I, C, N, Ch, Produced: Integer;
begin
  Ch:=Input.Channels;
  N:=Packet.Frames;
  if Length(Floats) < N * Ch then
    SetLength(Floats, N * Ch);
  case Input.SampleType of
    astFloat32: Move(Packet.Data^, Floats[0], N * Ch * SizeOf(Single));
    astInt16: for I:=0 to N * Ch - 1 do Floats[I]:=PSmallInt(Packet.Data)[I] / 32768;
    astInt32: for I:=0 to N * Ch - 1 do Floats[I]:=PInteger(Packet.Data)[I] / 2147483648.0;
  end;
  Lock.Acquire;
  try
    if Packet.Discontinuity then
      Inc(Discontinuities);
    if Sync = nil then
    begin
      Sync:=TAudioClockSync.Create(Ch, Input.SampleRate);
      SyncedDetector:=TDetector.Create(Input.SampleRate);
      RawDetector:=TDetector.Create(Input.SampleRate);
    end;
    if FirstCaptureUs < 0 then
      FirstCaptureUs:=Packet.CaptureTimeUs;
    // Raw path: device frame count at the nominal rate, as an uncorrected pipeline would stamp it.
    if Length(Mono) < N then
      SetLength(Mono, N);
    for I:=0 to N - 1 do
    begin
      Mono[I]:=0;
      for C:=0 to Ch - 1 do
        Mono[I]:=Mono[I] + Floats[I * Ch + C];
    end;
    RawDetector.Append(@Mono[0], N);
    // Synced path.
    Produced:=Sync.Push(@Floats[0], N, Packet.CaptureTimeUs, Output, 0, NOT Packet.TimestampError);
    if (Produced > 0) AND (SyncedFirstIndex < 0) then
      SyncedFirstIndex:=Sync.NextOutputFrame - Produced;
    if Produced > 0 then
    begin
      if Length(Mono) < Produced then
        SetLength(Mono, Produced);
      for I:=0 to Produced - 1 do
      begin
        Mono[I]:=0;
        for C:=0 to Ch - 1 do
          Mono[I]:=Mono[I] + Output[I * Ch + C];
      end;
      SyncedDetector.Append(@Mono[0], Produced);
    end;
  finally
    Lock.Release;
  end;
end;

procedure TTrack.HandleError(Sender: TObject; const Message: string);
begin
  Lock.Acquire;
  try
    Error:=Message;
  finally
    Lock.Release;
  end;
end;

function TTrack.ClickTimes: TArray<TClick>;
var
  I, N: Integer;
  Rate: Double;
begin
  Lock.Acquire;
  try
    Result:=nil;
    if Sync = nil then
      Exit;
    Rate:=Input.SampleRate;
    N:=Min(Length(SyncedDetector.Clicks), Length(RawDetector.Clicks));
    SetLength(Result, N);
    for I:=0 to N - 1 do
    begin
      // Synced output sample k belongs to QPC time OriginUs + k / rate exactly.
      Result[I].SyncedUs:=Sync.OriginUs + (SyncedFirstIndex + SyncedDetector.Clicks[I]) * 1E6 / Rate;
      Result[I].RawUs:=FirstCaptureUs + RawDetector.Clicks[I] * 1E6 / Rate;
    end;
  finally
    Lock.Release;
  end;
end;

function TTrack.Stats: TAudioClockSyncStats;
begin
  Lock.Acquire;
  try
    if Sync <> nil then
      Result:=Sync.Stats
    else
      Result:=Default(TAudioClockSyncStats);
  finally
    Lock.Release;
  end;
end;

{ TRenderThread }

procedure TRenderThread.Execute;
var
  Chunk, Ch, I, C, Bpf, Period, Pos: Integer;
  Buf: TBytes;
  V: Double;
  Sample: Int64;
begin
  Ch:=Output.Channels;
  Bpf:=Output.BytesPerFrame;
  Chunk:=Output.SampleRate DIV 100;
  Period:=Output.SampleRate * IntervalMs DIV 1000;
  SetLength(Buf, Chunk * Bpf);
  Sample:=0;
  while NOT Terminated do
  begin
    for I:=0 to Chunk - 1 do
    begin
      Pos:=(Sample + I) MOD Period;
      if Pos < Length(Template) then
        V:=Template[Pos]
      else
        V:=0;
      for C:=0 to Ch - 1 do
        if Output.SampleType = astFloat32 then
          PSingle(@Buf[(I * Ch + C) * 4])^:=V
        else
          PSmallInt(@Buf[(I * Ch + C) * 2])^:=Round(V * 32767);
    end;
    Inc(Accepted, Output.Write(@Buf[0], Length(Buf)));
    Inc(Offered, Length(Buf));
    Inc(Sample, Chunk);
  end;
end;

function FindDevice(const Needle: string; Render: Boolean; out Info: TAudioDeviceInfo): Boolean;
var
  D: TAudioDeviceInfo;
begin
  Result:=False;
  for D IN TAudioInputWASAPI.EnumerateDevices(Render) do
    if (D.State = 1) AND (Pos(LowerCase(Needle), LowerCase(D.FriendlyName)) > 0) then
    begin
      Info:=D;
      Exit(True);
    end;
end;

procedure List;
var
  D: TAudioDeviceInfo;
begin
  Writeln('Render endpoints (device A):');
  for D IN TAudioInputWASAPI.EnumerateDevices(True) do
    if D.State = 1 then
      Writeln('  ', D.FriendlyName);
  Writeln('Capture endpoints (device B):');
  for D IN TAudioInputWASAPI.EnumerateDevices(False) do
    if D.State = 1 then
      Writeln('  ', D.FriendlyName);
end;

function OpenTrack(const AName: string; const Info: TAudioDeviceInfo; Loopback: Boolean): TTrack;
begin
  Result:=TTrack.Create;
  Result.Name:=AName;
  Result.Input:=TAudioInputWASAPI.Create;
  Result.Input.DeviceId:=Info.Id;
  Result.Input.Loopback:=Loopback;
  // A real stream plays on A; no silent keep-alive needed.
  Result.Input.KeepLoopbackAlive:=False;
  Result.Input.OnData:=Result.HandleData;
  Result.Input.OnError:=Result.HandleError;
  Result.Input.Open;
  Writeln(Format('OPEN %s: %s, %d Hz, %d ch', [AName, Info.FriendlyName, Result.Input.SampleRate, Result.Input.Channels]));
end;

var
  Seconds, I, J, Paired, Expected: Integer;
  RenderInfo, CaptureInfo: TAudioDeviceInfo;
  Output: TAudioOutputWASAPI;
  Render: TRenderThread;
  A, B: TTrack;
  StartUs, NextLog: Int64;
  CA, CB: TArray<TClick>;
  Synced, Raw, BaseSynced, BaseRaw, MaxDev, Dev, RawDrift: Double;
  HaveBase: Boolean;
  Csv: TStringList;
  CsvFile: string;
  SA, SB: TAudioClockSyncStats;
  SameDevice: Boolean;
  Detector: TDetector;
  Ok: Boolean;

procedure Measure;
var
  I, J: Integer;
begin
  CA:=A.ClickTimes;
  CB:=B.ClickTimes;
  Paired:=0;
  J:=0;
  for I:=0 to High(CA) do
  begin
    while (J <= High(CB)) AND (CB[J].SyncedUs < CA[I].SyncedUs - IntervalMs * 500) do
      Inc(J);
    if (J > High(CB)) OR (Abs(CB[J].SyncedUs - CA[I].SyncedUs) > IntervalMs * 500) then
      Continue;
    Synced:=CB[J].SyncedUs - CA[I].SyncedUs;
    Raw:=CB[J].RawUs - CA[I].RawUs;
    if NOT HaveBase then
    begin
      BaseSynced:=Synced;
      BaseRaw:=Raw;
      HaveBase:=True;
    end;
    Dev:=Abs(Synced - BaseSynced);
    // Ignore the first 30 s while the drift fits converge.
    if (CA[I].SyncedUs - StartUs > 30E6) AND (Dev > MaxDev) then
      MaxDev:=Dev;
    RawDrift:=Raw - BaseRaw;
    Inc(Paired);
  end;
end;

begin
  try
    if (ParamCount >= 1) AND (ParamStr(1) = '--list') then
    begin
      List;
      Exit;
    end;
    if ParamCount < 3 then
    begin
      Writeln('Usage: AudioClockLoopTest --list | AudioClockLoopTest <seconds> <render A> <capture B | --same> [csv-file]');
      Halt(2);
    end;
    Seconds:=StrToInt(ParamStr(1));
    SameDevice:=ParamStr(3) = '--same';
    CsvFile:='';
    if ParamCount >= 4 then
      CsvFile:=ParamStr(4);
    if NOT FindDevice(ParamStr(2), True, RenderInfo) then
      raise Exception.Create('No render endpoint matches "' + ParamStr(2) + '"');
    if NOT SameDevice AND NOT FindDevice(ParamStr(3), False, CaptureInfo) then
      raise Exception.Create('No capture endpoint matches "' + ParamStr(3) + '"');

    Output:=TAudioOutputWASAPI.Create;
    Render:=TRenderThread.Create(True);
    Csv:=TStringList.Create;
    A:=nil;
    B:=nil;
    try
      Output.DeviceId:=RenderInfo.Id;
      Output.ApplyVolumeOnOpen:=False;
      Output.Open(48000, 2, 16);
      Writeln(Format('RENDER %s: %d Hz, %d ch, click every %d ms', [RenderInfo.FriendlyName, Output.SampleRate, Output.Channels, IntervalMs]));
      Detector:=TDetector.Create(Output.SampleRate);
      try
        SetLength(Render.Template, Length(Detector.FTemplate));
        for I:=0 to High(Detector.FTemplate) do
          Render.Template[I]:=Detector.FTemplate[I];
      finally
        Detector.Free;
      end;
      Render.Output:=Output;
      A:=OpenTrack('A', RenderInfo, True);
      if SameDevice then
        B:=OpenTrack('B', RenderInfo, True)
      else
        B:=OpenTrack('B', CaptureInfo, False);
      Csv.Add('elapsed_s,clicks_paired,synced_diff_us,synced_dev_us,raw_drift_us,a_ppm,b_ppm,a_resyncs,b_resyncs,a_disc,b_disc');

      Output.Start;
      Render.Start;
      A.Input.Start;
      B.Input.Start;
      StartUs:=AudioMonotonicUs;
      NextLog:=StartUs + 60000000;
      HaveBase:=False;
      MaxDev:=0;
      RawDrift:=0;
      while AudioMonotonicUs - StartUs < Int64(Seconds) * 1000000 do
      begin
        Sleep(200);
        if AudioMonotonicUs < NextLog then
          Continue;
        NextLog:=NextLog + 60000000;
        Measure;
        SA:=A.Stats;
        SB:=B.Stats;
        Writeln(Format('%6d s clicks %6d  synced B-A %9.1f us (dev %7.1f, max %7.1f)  raw drift %9.1f us  A %7.2f ppm  B %7.2f ppm  resyncs %d/%d  disc %d/%d %s%s',
          [(AudioMonotonicUs - StartUs) DIV 1000000, Paired, Synced, Abs(Synced - BaseSynced), MaxDev, RawDrift, SA.DriftPpm, SB.DriftPpm,
          SA.Resyncs, SB.Resyncs, A.Discontinuities, B.Discontinuities, A.Error, B.Error]));
        Csv.Add(Format('%d,%d,%.1f,%.1f,%.1f,%.3f,%.3f,%d,%d,%d,%d', [(AudioMonotonicUs - StartUs) DIV 1000000, Paired, Synced,
          Abs(Synced - BaseSynced), RawDrift, SA.DriftPpm, SB.DriftPpm, SA.Resyncs, SB.Resyncs, A.Discontinuities, B.Discontinuities],
          TFormatSettings.Invariant));
        if CsvFile <> '' then
          Csv.SaveToFile(CsvFile);
      end;
      Render.Terminate;
      Render.WaitFor;
      A.Input.Stop;
      B.Input.Stop;
      Measure;
      SA:=A.Stats;
      SB:=B.Stats;
      Expected:=Seconds * 1000 DIV IntervalMs;
      Ok:=HaveBase AND (MaxDev < FrameUs) AND (SA.Resyncs = 0) AND (SB.Resyncs = 0) AND (Paired >= Expected - 5) AND
        (A.Error = '') AND (B.Error = '');
      Writeln;
      Writeln(Format('RESULT %d s: %d/%d clicks paired; synced B-A %.1f us, moved at most %.1f us (limit %d us); ' +
        'uncorrected it would have drifted %.1f us; A %.3f ppm (%d resyncs, %d disc), B %.3f ppm (%d resyncs, %d disc): %s',
        [Seconds, Paired, Expected, BaseSynced, MaxDev, FrameUs, RawDrift, SA.DriftPpm, SA.Resyncs, A.Discontinuities, SB.DriftPpm,
        SB.Resyncs, B.Discontinuities, BoolToStr(Ok, True)]));
      Writeln(Format('RENDERED %d of %d bytes, device position %.2f s, sample type %d', [Render.Accepted, Render.Offered,
        Output.DevicePositionUs / 1E6, Ord(Output.SampleType)]));
      Writeln(Format('LEVELS A: %d clicks, peak %.4f; B: %d clicks, peak %.4f (trigger %.3f)', [Length(A.SyncedDetector.Clicks),
        A.SyncedDetector.Peak, Length(B.SyncedDetector.Clicks), B.SyncedDetector.Peak, TriggerLevel]));
      if CsvFile <> '' then
        Csv.SaveToFile(CsvFile);
      if NOT Ok then
        ExitCode:=1;
    finally
      Render.Free;
      A.Free;
      B.Free;
      Output.Free;
      Csv.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
