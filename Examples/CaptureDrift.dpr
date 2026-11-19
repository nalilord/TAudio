program CaptureDrift;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}
{$POINTERMATH ON}

{
  Captures one or more WASAPI endpoints at once and locks each to the QPC clock
  with TAudioClockSync. Prints every device's measured sample rate, drift against
  QPC, alignment error and glitch counters.

    CaptureDrift --list
    CaptureDrift <seconds> <device> [<device> ...]

  <device> is a substring of a capture endpoint's name, or "loopback:<substring>"
  for a render endpoint. Exit code 1 if any device resynced, glitched or drifted
  beyond one video frame (16.7 ms) of alignment error after convergence.
}

uses
  SysUtils, Classes, SyncObjs,
  TAudio.Types, TAudio.Clock, TAudio.Input, TAudio.Input.WASAPI, TAudio.ClockSync;

type
  TDevice = class
  public
    Name: string;
    Input: TAudioInputWASAPI;
    Sync: TAudioClockSync;
    Lock: TCriticalSection;
    Floats: TArray<Single>;
    Output: TArray<Single>;
    Stats: TAudioClockSyncStats;
    Discontinuities, TimestampErrors, Silent: Int64;
    FirstDevicePosition: Int64;
    Errors: string;
    Dump: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure HandleData(Sender: TObject; const Packet: TAudioInputPacket);
    procedure HandleError(Sender: TObject; const Message: string);
  end;

constructor TDevice.Create;
begin
  Lock:=TCriticalSection.Create;
  FirstDevicePosition:=-1;
end;

destructor TDevice.Destroy;
begin
  Input.Free;
  Dump.Free;
  Sync.Free;
  Lock.Free;
  inherited;
end;

procedure TDevice.HandleData(Sender: TObject; const Packet: TAudioInputPacket);
var
  I, N: Integer;
begin
  N:=Packet.Frames * Input.Channels;
  if Length(Floats) < N then
    SetLength(Floats, N);
  case Input.SampleType of
    astFloat32: Move(Packet.Data^, Floats[0], N * SizeOf(Single));
    astInt16: for I:=0 to N - 1 do Floats[I]:=PSmallInt(Packet.Data)[I] / 32768;
    astInt32: for I:=0 to N - 1 do Floats[I]:=PInteger(Packet.Data)[I] / 2147483648.0;
  end;
  if Sync = nil then
    Sync:=TAudioClockSync.Create(Input.Channels, Input.SampleRate);
  Sync.Push(@Floats[0], Packet.Frames, Packet.CaptureTimeUs, Output, 0, NOT Packet.TimestampError);
  if Dump <> nil then
    Dump.Add(Format('%d,%d,%d,%d,%d,%d', [Packet.DevicePosition, Packet.CaptureTimeUs, Packet.Frames, Ord(Packet.Discontinuity),
      Ord(Packet.TimestampError), Ord(Packet.Silent)]));
  Lock.Acquire;
  try
    Stats:=Sync.Stats;
    if Packet.Discontinuity then
      Inc(Discontinuities);
    if Packet.TimestampError then
      Inc(TimestampErrors);
    if Packet.Silent then
      Inc(Silent);
    if FirstDevicePosition < 0 then
      FirstDevicePosition:=Packet.DevicePosition;
  finally
    Lock.Release;
  end;
end;

procedure TDevice.HandleError(Sender: TObject; const Message: string);
begin
  Lock.Acquire;
  try
    Errors:=Message;
  finally
    Lock.Release;
  end;
end;

function FindDevice(const Spec: string; out Loopback: Boolean; out Info: TAudioDeviceInfo): Boolean;
var
  Needle: string;
  D: TAudioDeviceInfo;
begin
  Loopback:=SameText(Copy(Spec, 1, 9), 'loopback:');
  Needle:=Spec;
  if Loopback then
    Needle:=Copy(Spec, 10, MaxInt);
  Result:=False;
  for D IN TAudioInputWASAPI.EnumerateDevices(Loopback) do
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
  Writeln('Capture endpoints:');
  for D IN TAudioInputWASAPI.EnumerateDevices(False) do
    if D.State = 1 then
      if D.IsDefault then Writeln('  ', D.FriendlyName, ' (default)') else Writeln('  ', D.FriendlyName);
  Writeln('Render endpoints (use loopback:<name>):');
  for D IN TAudioInputWASAPI.EnumerateDevices(True) do
    if D.State = 1 then
      if D.IsDefault then Writeln('  ', D.FriendlyName, ' (default)') else Writeln('  ', D.FriendlyName);
end;

var
  Devices: TList;
  Device: TDevice;
  Info: TAudioDeviceInfo;
  Loopback, Bad: Boolean;
  Seconds, I: Integer;
  StartUs, NextReport: Int64;
  S: TAudioClockSyncStats;
  Disc, TsErr, Sil: Int64;
  Err: string;
  DumpBase: string;
  FirstDevice: Integer;
begin
  try
    if (ParamCount >= 1) AND (ParamStr(1) = '--list') then
    begin
      List;
      Exit;
    end;
    if ParamCount < 2 then
    begin
      Writeln('Usage: CaptureDrift --list | CaptureDrift <seconds> <device> [<device> ...]');
      Halt(2);
    end;
    Seconds:=StrToInt(ParamStr(1));
    DumpBase:='';
    FirstDevice:=2;
    if (ParamCount >= 3) AND (ParamStr(2) = '--dump') then
    begin
      // CaptureDrift <seconds> --dump <file-prefix> <device> ...: per-packet CSV per device.
      DumpBase:=ParamStr(3);
      FirstDevice:=4;
    end;
    Devices:=TList.Create;
    try
      for I:=FirstDevice to ParamCount do
      begin
        if NOT FindDevice(ParamStr(I), Loopback, Info) then
          raise Exception.Create('No active endpoint matches "' + ParamStr(I) + '"');
        Device:=TDevice.Create;
        Devices.Add(Device);
        Device.Name:=Info.FriendlyName;
        if Loopback then
          Device.Name:='loopback ' + Device.Name;
        Device.Input:=TAudioInputWASAPI.Create;
        if DumpBase <> '' then
        begin
          Device.Dump:=TStringList.Create;
          Device.Dump.Add('device_position,capture_us,frames,discontinuity,timestamp_error,silent');
        end;
        Device.Input.DeviceId:=Info.Id;
        Device.Input.Loopback:=Loopback;
        Device.Input.OnData:=Device.HandleData;
        Device.Input.OnError:=Device.HandleError;
        Device.Input.Open;
        Writeln(Format('OPEN %s: %d Hz, %d ch, %d-bit, event-driven %s', [Device.Name, Device.Input.SampleRate,
          Device.Input.Channels, Device.Input.BitsPerSample, BoolToStr(Device.Input.EventDriven, True)]));
      end;
      for I:=0 to Devices.Count - 1 do
        TDevice(Devices[I]).Input.Start;
      StartUs:=AudioMonotonicUs;
      NextReport:=StartUs + 10000000;
      while AudioMonotonicUs - StartUs < Int64(Seconds) * 1000000 do
      begin
        Sleep(100);
        if AudioMonotonicUs < NextReport then
          Continue;
        NextReport:=NextReport + 10000000;
        for I:=0 to Devices.Count - 1 do
        begin
          Device:=TDevice(Devices[I]);
          Device.Lock.Acquire;
          try
            S:=Device.Stats;
            Disc:=Device.Discontinuities;
            TsErr:=Device.TimestampErrors;
            Err:=Device.Errors;
          finally
            Device.Lock.Release;
          end;
          Writeln(Format('%6d s %-45s rate %10.3f Hz drift %8.2f ppm err %8.1f us max %8.1f us corr %8.2f ppm resyncs %d disc %d tserr %d %s',
            [(AudioMonotonicUs - StartUs) DIV 1000000, Copy(Device.Name, 1, 45), S.DeviceRateHz, S.DriftPpm, S.ErrorUs,
            S.MaxAbsErrorUs, S.CorrectionPpm, S.Resyncs, Disc, TsErr, Err]));
        end;
      end;
      Bad:=False;
      Writeln;
      for I:=0 to Devices.Count - 1 do
      begin
        Device:=TDevice(Devices[I]);
        Device.Input.Stop;
        if Device.Dump <> nil then
          Device.Dump.SaveToFile(Format('%s-%d.csv', [DumpBase, I]));
        S:=Device.Stats;
        Disc:=Device.Discontinuities;
        TsErr:=Device.TimestampErrors;
        Sil:=Device.Silent;
        Writeln(Format('RESULT %s: %.3f Hz (%.2f ppm), max alignment error %.1f us, resyncs %d, skipped %d, silence %d+%d, ' +
          'discontinuities %d, timestamp errors %d, silent packets %d, packets %d %s',
          [Device.Name, S.DeviceRateHz, S.DriftPpm, S.MaxAbsErrorUs, S.Resyncs, S.SkippedFrames, S.SilenceInputFrames,
          S.SilenceOutputFrames, Disc, TsErr, Sil, Device.Input.Packets, Device.Errors]));
        if (S.Resyncs > 0) OR (Disc > 0) OR (S.MaxAbsErrorUs > 16667) OR (Device.Errors <> '') then
          Bad:=True;
      end;
      if Bad then
        ExitCode:=1;
    finally
      for I:=0 to Devices.Count - 1 do
        TDevice(Devices[I]).Free;
      Devices.Free;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
