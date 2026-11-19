program AudioClockLoopTest;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}
{$APPTYPE CONSOLE}
{$POINTERMATH ON}

{
  Long-run acoustic loop test for TAudioClockSync (PasAV HardwareEncodePlan E07.3).

  Device A plays a click every IntervalMs at exact frames of its render stream. A
  cable carries A's output into device B's input.

    A: the render device clock. IAudioClock.GetPosition reports which stream
       frame is playing and when (QPC); each click's play time is interpolated
       from those readings. No loopback: driver effects and other sounds on A's
       mix cannot produce false clicks.
    B: B's capture endpoint, locked to QPC with TAudioClockSync; each click's
       arrival is timed by cross-correlation with the click template.

  B - A is the analog path delay and must stay constant. The same difference
  with both devices taken at their nominal rate (no clock correction) is logged
  beside it and drifts by the devices' ppm difference.

    AudioClockLoopTest --list
    AudioClockLoopTest <seconds> <render A> <capture B> [csv-file]

  The CSV holds one row per minute; <csv-file>-clicks.csv one row per click.
  Exit 1 if B - A moves by more than one video frame (16.7 ms) after the first
  minute, B resyncs, or clicks go missing.
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
  // Finds click onsets in a mono stream.
  TDetector = class
  private
    FRate: Integer;
    FHistory: TArray<Single>;
    FHistoryStart: Int64;     // sample index of FHistory[0]
    FCount: Int64;            // samples appended so far
    FPendingTrigger: Int64;   // sample index of a trigger waiting for its window, or -1
    FLastClick: Int64;
    function SampleAt(Index: Int64): Double;
  public
    Template: TArray<Double>;
    Clicks: TArray<Double>;   // onsets, fractional sample index in the stream
    Peak: Double;
    constructor Create(Rate: Integer);
    procedure Append(Data: PSingle; Frames: Integer);
  end;

  TCapture = class
  public
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
    function Stats: TAudioClockSyncStats;
  end;

  // Plays the click train and turns device position readings into click play times.
  TRenderThread = class(TThread)
  public
    Output: TAudioOutputWASAPI;
    Template: TArray<Double>;
    Lock: TCriticalSection;
    ClickUs: TArray<Double>;   // QPC play time of click k
    Accepted, Offered: Int64;
    FirstPos, LastPos: Int64;
    FirstQpc, LastQpc: Int64;
    Readings: Int64;
    procedure Execute; override;
  end;

  TPair = record
    K: Integer;
    AUs, ANominalUs, BSyncedUs, BRawUs: Double;
  end;

{ TDetector }

constructor TDetector.Create(Rate: Integer);
var
  I, N: Integer;
begin
  FRate:=Rate;
  N:=Rate * BurstMs DIV 1000;
  SetLength(Template, N);
  for I:=0 to N - 1 do
    Template[I]:=Sin(2 * Pi * BurstHz * I / Rate) * 0.5 * (1 - Cos(2 * Pi * I / (N - 1)));
  FPendingTrigger:=-1;
  FLastClick:=-Int64(Rate) * 10;
end;

function TDetector.SampleAt(Index: Int64): Double;
begin
  Result:=FHistory[Index - FHistoryStart];
end;

procedure TDetector.Append(Data: PSingle; Frames: Integer);
var
  I, Lag, BestLag, N, Keep, Drop, K: Integer;
  WindowStart: Int64;
  C, Best, Prev, Next, Denom, Offset: Double;
  Corr: array of Double;
begin
  N:=Length(FHistory);
  SetLength(FHistory, N + Frames);
  Move(Data^, FHistory[N], Frames * SizeOf(Single));
  for I:=0 to Frames - 1 do
  begin
    if Abs(Data[I]) > Peak then
      Peak:=Abs(Data[I]);
    if (FPendingTrigger < 0) AND (Abs(Data[I]) > TriggerLevel) AND (FCount + I - FLastClick > FRate * IntervalMs DIV 2000) then
      FPendingTrigger:=FCount + I;
  end;
  Inc(FCount, Frames);

  // Correlate once the window [trigger - 3 ms, trigger + 3 ms + template] is complete.
  if (FPendingTrigger >= 0) AND (FCount >= FPendingTrigger + FRate * 3 DIV 1000 + Length(Template) + 2) then
  begin
    WindowStart:=Max(FHistoryStart, FPendingTrigger - FRate * 3 DIV 1000);
    SetLength(Corr, FRate * 6 DIV 1000);
    Best:=-1;
    BestLag:=0;
    for Lag:=0 to High(Corr) do
    begin
      C:=0;
      for K:=0 to High(Template) do
        C:=C + Template[K] * SampleAt(WindowStart + Lag + K);
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

{ TCapture }

constructor TCapture.Create;
begin
  Lock:=TCriticalSection.Create;
  FirstCaptureUs:=-1;
  SyncedFirstIndex:=-1;
end;

destructor TCapture.Destroy;
begin
  Input.Free;
  Sync.Free;
  SyncedDetector.Free;
  RawDetector.Free;
  Lock.Free;
  inherited;
end;

procedure TCapture.HandleData(Sender: TObject; const Packet: TAudioInputPacket);
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
    // Raw path: device frames at the nominal rate, as an uncorrected pipeline would stamp them.
    if Length(Mono) < N then
      SetLength(Mono, N);
    for I:=0 to N - 1 do
    begin
      Mono[I]:=0;
      for C:=0 to Ch - 1 do
        Mono[I]:=Mono[I] + Floats[I * Ch + C];
    end;
    RawDetector.Append(@Mono[0], N);
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

procedure TCapture.HandleError(Sender: TObject; const Message: string);
begin
  Lock.Acquire;
  try
    Error:=Message;
  finally
    Lock.Release;
  end;
end;

function TCapture.Stats: TAudioClockSyncStats;
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
  Chunk, Ch, I, C, Period, Pos: Integer;
  Buf: TBytes;
  V: Double;
  Sample, DevPos, PrevPos, ClickFrame: Int64;
  Qpc, PrevQpc: Int64;
begin
  Ch:=Output.Channels;
  Chunk:=Output.SampleRate DIV 100;
  Period:=Output.SampleRate * IntervalMs DIV 1000;
  SetLength(Buf, Chunk * Output.BytesPerFrame);
  Sample:=0;
  PrevPos:=-1;
  PrevQpc:=0;
  FirstPos:=-1;
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

    // Click k starts at stream frame k * Period; find its play time between two readings.
    if Output.DevicePositionQpc(DevPos, Qpc) AND (DevPos > 0) then
    begin
      Inc(Readings);
      if FirstPos < 0 then
      begin
        FirstPos:=DevPos;
        FirstQpc:=Qpc;
      end;
      LastPos:=DevPos;
      LastQpc:=Qpc;
      if (PrevPos >= 0) AND (DevPos > PrevPos) then
      begin
        Lock.Acquire;
        try
          ClickFrame:=Int64(Length(ClickUs)) * Period;
          while ClickFrame <= DevPos do
          begin
            if ClickFrame >= PrevPos then
            begin
              SetLength(ClickUs, Length(ClickUs) + 1);
              ClickUs[High(ClickUs)]:=PrevQpc + (ClickFrame - PrevPos) * (Qpc - PrevQpc) / (DevPos - PrevPos);
            end else
            begin
              // Played before the first usable reading: mark unknown.
              SetLength(ClickUs, Length(ClickUs) + 1);
              ClickUs[High(ClickUs)]:=-1;
            end;
            ClickFrame:=Int64(Length(ClickUs)) * Period;
          end;
        finally
          Lock.Release;
        end;
      end;
      PrevPos:=DevPos;
      PrevQpc:=Qpc;
    end;
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

var
  Seconds, Expected: Integer;
  RenderInfo, CaptureInfo: TAudioDeviceInfo;
  Output: TAudioOutputWASAPI;
  Render: TRenderThread;
  B: TCapture;
  StartUs, NextLog: Int64;
  Pairs: TArray<TPair>;
  Latency, BaseSynced, BaseRaw, MaxDev, LastSynced, LastRawDrift, APpm: Double;
  Csv, ClickLog: TStringList;
  CsvFile: string;
  SB: TAudioClockSyncStats;
  Ok: Boolean;

// Pairs every click k (A play time) with B's synced detection near A + latency, and with
// B's raw detection of the same onset.
procedure Measure;
var
  A: TArray<Double>;
  BS, BR: TArray<Double>;
  Rate, Want, BSyncedUs, BRawUs, SyncedDiff, RawDiff, Tmp: Double;
  I, J, R, K: Integer;
  Lat: TArray<Double>;
  Origin: Int64;
  FirstSynced: Int64;
begin
  Render.Lock.Acquire;
  try
    A:=Copy(Render.ClickUs);
  finally
    Render.Lock.Release;
  end;
  B.Lock.Acquire;
  try
    if B.Sync = nil then
      Exit;
    BS:=Copy(B.SyncedDetector.Clicks);
    BR:=Copy(B.RawDetector.Clicks);
    Origin:=B.Sync.OriginUs;
    FirstSynced:=B.SyncedFirstIndex;
  finally
    B.Lock.Release;
  end;
  Rate:=B.Input.SampleRate;
  // Synced onsets in QPC microseconds; raw onsets at B's nominal rate from its first packet.
  for I:=0 to High(BS) do
    BS[I]:=Origin + (FirstSynced + BS[I]) * 1E6 / Rate;
  for I:=0 to High(BR) do
    BR[I]:=B.FirstCaptureUs + BR[I] * 1E6 / Rate;

  if Latency = 0 then
  begin
    Lat:=nil;
    J:=0;
    for K:=0 to Min(High(A), 30) do
    begin
      if A[K] < 0 then
        Continue;
      while (J <= High(BS)) AND (BS[J] < A[K]) do
        Inc(J);
      if (J <= High(BS)) AND (BS[J] - A[K] < IntervalMs * 500) then
      begin
        SetLength(Lat, Length(Lat) + 1);
        Lat[High(Lat)]:=BS[J] - A[K];
      end;
    end;
    if Length(Lat) < 5 then
      Exit;
    for I:=1 to High(Lat) do
      for K:=I downto 1 do
        if Lat[K] < Lat[K - 1] then
        begin
          Tmp:=Lat[K];
          Lat[K]:=Lat[K - 1];
          Lat[K - 1]:=Tmp;
        end;
    Latency:=Lat[Length(Lat) DIV 2];
  end;

  Pairs:=nil;
  J:=0;
  R:=0;
  for K:=0 to High(A) do
  begin
    if A[K] < 0 then
      Continue;
    Want:=A[K] + Latency;
    while (J <= High(BS)) AND (BS[J] < Want - 20000) do
      Inc(J);
    if (J > High(BS)) OR (Abs(BS[J] - Want) > 20000) then
      Continue;
    BSyncedUs:=BS[J];
    // The raw detection of the same onset lies within a few ms of the synced one.
    while (R <= High(BR)) AND (BR[R] < BSyncedUs - 50000) do
      Inc(R);
    if (R > High(BR)) OR (Abs(BR[R] - BSyncedUs) > 50000) then
      Continue;
    BRawUs:=BR[R];
    SetLength(Pairs, Length(Pairs) + 1);
    Pairs[High(Pairs)].K:=K;
    Pairs[High(Pairs)].AUs:=A[K];
    // A at its nominal rate from the first reading: what an uncorrected pipeline assumes.
    Pairs[High(Pairs)].ANominalUs:=Render.FirstQpc + (Int64(K) * (Output.SampleRate * IntervalMs DIV 1000) - Render.FirstPos) * 1E6 /
      Output.SampleRate;
    Pairs[High(Pairs)].BSyncedUs:=BSyncedUs;
    Pairs[High(Pairs)].BRawUs:=BRawUs;
  end;

  ClickLog.Clear;
  ClickLog.Add('click,a_us,a_nominal_us,b_synced_us,b_raw_us,synced_diff_us,raw_diff_us');
  MaxDev:=0;
  for I:=0 to High(Pairs) do
  begin
    SyncedDiff:=Pairs[I].BSyncedUs - Pairs[I].AUs;
    RawDiff:=Pairs[I].BRawUs - Pairs[I].ANominalUs;
    if I = 0 then
    begin
      BaseSynced:=SyncedDiff;
      BaseRaw:=RawDiff;
    end;
    // Ignore the first minute while B's drift fit converges.
    if (Pairs[I].AUs - StartUs > 60E6) AND (Abs(SyncedDiff - BaseSynced) > MaxDev) then
      MaxDev:=Abs(SyncedDiff - BaseSynced);
    LastSynced:=SyncedDiff;
    LastRawDrift:=RawDiff - BaseRaw;
    ClickLog.Add(Format('%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f', [Pairs[I].K, Pairs[I].AUs - StartUs, Pairs[I].ANominalUs - StartUs,
      Pairs[I].BSyncedUs - StartUs, Pairs[I].BRawUs - StartUs, SyncedDiff, RawDiff], TFormatSettings.Invariant));
  end;
  if (Render.LastPos > Render.FirstPos) AND (Render.LastQpc > Render.FirstQpc) then
    APpm:=((Render.LastPos - Render.FirstPos) * 1E6 / Output.SampleRate / (Render.LastQpc - Render.FirstQpc) - 1) * 1E6;
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
      Writeln('Usage: AudioClockLoopTest --list | AudioClockLoopTest <seconds> <render A> <capture B> [csv-file]');
      Halt(2);
    end;
    Seconds:=StrToInt(ParamStr(1));
    CsvFile:='';
    if ParamCount >= 4 then
      CsvFile:=ParamStr(4);
    if NOT FindDevice(ParamStr(2), True, RenderInfo) then
      raise Exception.Create('No render endpoint matches "' + ParamStr(2) + '"');
    if NOT FindDevice(ParamStr(3), False, CaptureInfo) then
      raise Exception.Create('No capture endpoint matches "' + ParamStr(3) + '"');

    Output:=TAudioOutputWASAPI.Create;
    Render:=TRenderThread.Create(True);
    Render.Lock:=TCriticalSection.Create;
    B:=TCapture.Create;
    Csv:=TStringList.Create;
    ClickLog:=TStringList.Create;
    try
      Output.DeviceId:=RenderInfo.Id;
      Output.ApplyVolumeOnOpen:=False;
      Output.RequireClock:=True;
      Output.Open(48000, 2, 16);
      Writeln(Format('RENDER A %s: %d Hz, %d ch, click every %d ms', [RenderInfo.FriendlyName, Output.SampleRate, Output.Channels,
        IntervalMs]));
      with TDetector.Create(Output.SampleRate) do
        try
          Render.Template:=Copy(Template);
        finally
          Free;
        end;
      Render.Output:=Output;
      B.Input:=TAudioInputWASAPI.Create;
      B.Input.DeviceId:=CaptureInfo.Id;
      B.Input.OnData:=B.HandleData;
      B.Input.OnError:=B.HandleError;
      B.Input.Open;
      Writeln(Format('CAPTURE B %s: %d Hz, %d ch', [CaptureInfo.FriendlyName, B.Input.SampleRate, B.Input.Channels]));
      Csv.Add('elapsed_s,clicks_paired,synced_diff_us,synced_dev_us,raw_drift_us,a_ppm,b_ppm,b_resyncs,b_disc');

      StartUs:=AudioMonotonicUs;
      Latency:=0;
      Output.Start;
      Render.Start;
      B.Input.Start;
      NextLog:=StartUs + 60000000;
      while AudioMonotonicUs - StartUs < Int64(Seconds) * 1000000 do
      begin
        Sleep(200);
        if AudioMonotonicUs < NextLog then
          Continue;
        NextLog:=NextLog + 60000000;
        Measure;
        SB:=B.Stats;
        Writeln(Format('%6d s clicks %6d  B-A %9.1f us (max dev %7.1f)  uncorrected drift %10.1f us  A %7.3f ppm  B %7.2f ppm  resyncs %d disc %d %s',
          [(AudioMonotonicUs - StartUs) DIV 1000000, Length(Pairs), LastSynced, MaxDev, LastRawDrift, APpm, SB.DriftPpm, SB.Resyncs,
          B.Discontinuities, B.Error]));
        Csv.Add(Format('%d,%d,%.1f,%.1f,%.1f,%.3f,%.3f,%d,%d', [(AudioMonotonicUs - StartUs) DIV 1000000, Length(Pairs), LastSynced, MaxDev,
          LastRawDrift, APpm, SB.DriftPpm, SB.Resyncs, B.Discontinuities], TFormatSettings.Invariant));
        if CsvFile <> '' then
        begin
          Csv.SaveToFile(CsvFile);
          ClickLog.SaveToFile(ChangeFileExt(CsvFile, '') + '-clicks.csv');
        end;
      end;
      Render.Terminate;
      Render.WaitFor;
      B.Input.Stop;
      Measure;
      SB:=B.Stats;
      Expected:=Seconds * 1000 DIV IntervalMs;
      Ok:=(Length(Pairs) >= Expected - 5) AND (MaxDev < FrameUs) AND (SB.Resyncs = 0) AND (B.Error = '');
      Writeln;
      Writeln(Format('RESULT %d s: %d/%d clicks paired; B-A %.1f us (latency), moved at most %.1f us after the first minute ' +
        '(limit %d us); uncorrected it drifted %.1f us; A %.3f ppm (render clock), B %.3f ppm (%d resyncs, %d disc): %s',
        [Seconds, Length(Pairs), Expected, Latency, MaxDev, FrameUs, LastRawDrift, APpm, SB.DriftPpm, SB.Resyncs, B.Discontinuities,
        BoolToStr(Ok, True)]));
      Writeln(Format('DIAG render accepted %d of %d bytes, %d clock readings; B detections synced %d raw %d, peak %.4f',
        [Render.Accepted, Render.Offered, Render.Readings, Length(B.SyncedDetector.Clicks), Length(B.RawDetector.Clicks),
        B.SyncedDetector.Peak]));
      if CsvFile <> '' then
      begin
        Csv.SaveToFile(CsvFile);
        ClickLog.SaveToFile(ChangeFileExt(CsvFile, '') + '-clicks.csv');
      end;
      if NOT Ok then
        ExitCode:=1;
    finally
      Render.Lock.Free;
      Render.Free;
      B.Free;
      Output.Free;
      Csv.Free;
      ClickLog.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
