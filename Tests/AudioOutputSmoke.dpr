program AudioOutputSmoke;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  TAudio.Output, TAudio.Output.WaveOut, TAudio.Output.WASAPI, TAudio.Windows,
  TAudio.Types;

procedure Check(Value: Boolean; const Text: string);
begin
  if NOT Value then
    raise Exception.Create(Text);
end;

type
  EProbeOutputError = class(EAudioOutputError);
  TCancelThread = class(TThread)
    Event: TEvent;
    procedure Execute; override;
  end;

procedure TCancelThread.Execute;
begin
  Sleep(30);
  Event.SetEvent;
end;

procedure Exercise(Output: TAudioOutput);
var
  PCM: TBytes;
  Stop: TEvent;
  Cancel: TCancelThread;
  Played, Submitted: Int64;
  Wrote: Integer;
begin
  Stop:=TEvent.Create(nil, True, False, '');
  try
    Output.StopEvent:=Stop;
    Output.Pause;
    Output.BlockingWrites:=False;
    SetLength(PCM, Output.SampleRate DIV 20 * Output.BytesPerFrame);
    if Output.SampleType = astUInt8 then
      FillChar(PCM[0], Length(PCM), 128);
    Check(Output.Write(@PCM[0], Length(PCM)) = Length(PCM), 'Queue PCM while paused');
    Check(Output.GetBufferedBytes > 0, 'Paused queue retained');
    Sleep(20);
    Check(Output.GetBufferedBytes > 0, 'Pause must preserve queued samples');
    Output.Start;
    Check(Output.WaitUntilDrained(2000), 'Drain timed out');
    Check(Output.GetMeterPosition(Played, Submitted), 'Device clock unavailable');
    Check((Played > 0) AND (Submitted >= Length(PCM) DIV Output.BytesPerFrame), 'Clock did not advance');
    Output.Pause;
    Check(Output.Write(@PCM[0], Length(PCM)) > 0, 'Queue before flush');
    Output.Flush;
    Check(Output.GetBufferedBytes = 0, 'Flush did not discard queued PCM');
    Check(Output.GetMeterPosition(Played, Submitted) AND (Submitted = 0), 'Flush epoch not reset');
    Output.BlockingWrites:=True;
    SetLength(PCM, Output.SampleRate * 3 * Output.BytesPerFrame);
    if Output.SampleType = astUInt8 then
      FillChar(PCM[0], Length(PCM), 128);
    Cancel:=TCancelThread.Create(True);
    try
      Cancel.Event:=Stop;
      Cancel.Start;
      Wrote:=Output.Write(@PCM[0], Length(PCM));
      Check(Wrote < Length(PCM), 'Blocked write did not cancel');
      Cancel.WaitFor;
    finally
      Cancel.Free;
    end;
    Output.Stop;
    Output.Close;
    Output.Close;
    WriteLn('PASS ', Output.ClassName, ': pause, clock, drain, flush, cancellation, close');
  finally
    Output.StopEvent:=nil;
    Stop.Free;
  end;
end;

var
  Wave: TAudioOutputWaveOut;
  WASAPI: TAudioOutputWASAPI;
  Sample: TAudioSampleType;
  Devices: TAudioDeviceInfos;
  Device: TAudioDeviceInfo;
  FailedOpen, FoundDefault: Boolean;
begin
  try
    Check(SizeOf(TAudio.Windows.TWaveFormatEx) = 18, 'WAVEFORMATEX ABI');
    Check(SizeOf(TAudioPropVariant) = 8 + 2 * SizeOf(Pointer), 'PROPVARIANT ABI');
    Wave:=TAudioOutputWaveOut.Create;
    try
      Wave.ApplyVolumeOnOpen:=False;
      for Sample:=Low(TAudioSampleType) to High(TAudioSampleType) do
      begin
        Check(Wave.OpenPCM(48000, 2, Sample), 'WaveOut open');
        Exercise(Wave);
      end;
      Wave.OutputErrorClass:=EProbeOutputError;
      Wave.DeviceId:=High(Cardinal) - 1;
      FailedOpen:=False;
      try
        Wave.OpenPCM(48000, 2, astInt16);
      except
        on E: EProbeOutputError do
          FailedOpen:=True;
      end;
      Check(FailedOpen, 'WaveOut native exception type');
      Wave.DeviceId:=High(Cardinal);
      Check(Wave.OpenPCM(48000, 2, astInt16), 'WaveOut failed-open recovery');
      Wave.Close;
    finally
      Wave.Free;
    end;
    WASAPI:=TAudioOutputWASAPI.Create;
    try
      WASAPI.ApplyVolumeOnOpen:=False;
      Devices:=WASAPI.EnumerateDevices;
      Check(Length(Devices) > 0, 'Device enumeration');
      FoundDefault:=False;
      for Device IN Devices do
        if Device.IsDefault then
        begin
          Check((Device.Id <> '') AND (Device.FriendlyName <> '') AND
            (Device.State <> 0) AND (Device.StateText <> ''), 'Device properties');
          WASAPI.DeviceId:=Device.Id;
          FoundDefault:=True;
        end;
      Check(FoundDefault, 'Default device identification');
      Check(WASAPI.Open(48000, 2, 16), 'Mix-format open');
      Exercise(WASAPI);
      WASAPI.DeviceId:='TAudio deliberately invalid endpoint';
      WASAPI.OutputErrorClass:=EProbeOutputError;
      FailedOpen:=False;
      try
        WASAPI.Open(48000, 2, 16);
      except
        on E: EProbeOutputError do
          FailedOpen:=True;
      end;
      Check(FailedOpen AND (WASAPI.GetBufferedBytes = 0), 'Failed-open cleanup');
      WASAPI.DeviceId:='';
      Check(WASAPI.OpenPCM(48000, 2, astFloat32), 'Explicit PCM open');
      Exercise(WASAPI);
    finally
      WASAPI.Free;
    end;
  except
    on E: Exception do
    begin
      WriteLn('FAIL: ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
