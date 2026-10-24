unit TAudio.Output.WASAPI;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$POINTERMATH ON}

interface

uses
{$IFDEF FPC}
  Windows, ActiveX, SysUtils, SyncObjs,
{$ELSE}
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.SyncObjs,
{$ENDIF}
  TAudio.Output, TAudio.Types, TAudio.Windows;

type
  TPackedWaveFormatEx = packed record
    wFormatTag: Word;
    nChannels: Word;
    nSamplesPerSec: DWORD;
    nAvgBytesPerSec: DWORD;
    nBlockAlign: Word;
    wBitsPerSample: Word;
    cbSize: Word;
  end;

  PPackedWaveFormatExtensible = ^TPackedWaveFormatExtensible;
  TPackedWaveFormatExtensible = packed record
    Format: TPackedWaveFormatEx;
    Samples: packed record
      case Integer of
        0: (wValidBitsPerSample: Word);
        1: (wSamplesPerBlock: Word);
        2: (wReserved: Word);
    end;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

  TAudioOutputWASAPI = class(TAudioOutput)
  private
    FCoInitialized: Boolean;
    FApplyVolumeOnOpen: Boolean;
    FRequireClock: Boolean;
    FEnumerator: IMMDeviceEnumerator;
    FDevice: IMMDevice;
    FAudioClient: IAudioClient;
    FRenderClient: IAudioRenderClient;
    FAudioClock: IAudioClock;
    FClockFrequency: UInt64;
    FWriteEndFrame: Int64;
    FLastClockFrame: Int64;
    FHasWritten: Boolean;
    FSimpleVolume: ISimpleAudioVolume;
    FEndpointVolume: IAudioEndpointVolume;
    FBufferFrameCount: UINT32;
    FLatencyHns: Int64;
    FStarted: Boolean;
    FDeviceId: string;
    FVolumeMode: TAudioVolumeMode;
    function DoOpen(ARate, AChannels, ABits: Integer; AType: TAudioSampleType; UseMixFormat: Boolean): Boolean;
    procedure ApplyVolume;
    procedure CheckHR(HR: HResult; const Action: string);
    procedure AdoptWaveFormat(const Format: PWAVEFORMATEX);
    procedure SetVolumeMode(const Value: TAudioVolumeMode);
    class procedure CheckHRStatic(HR: HResult; const Action: string); static;
    class function GetDeviceIdString(const Device: IMMDevice): string; static;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Open(SampleRate, Channels, BitsPerSample: Integer): Boolean; override;
    function OpenPCM(ARate, AChannels: Integer; AType: TAudioSampleType): Boolean;
    procedure Pause; override;
    procedure Flush; override;
    function DevicePositionUs: Int64; override;
    function DeviceLatencyUs: Int64; override;
    property ApplyVolumeOnOpen: Boolean read FApplyVolumeOnOpen write FApplyVolumeOnOpen;
    property RequireClock: Boolean read FRequireClock write FRequireClock;
    procedure Close; override;
    procedure Start; override;
    procedure Stop; override;
    function Write(Buffer: PByte; ByteCount: Integer): Integer; override;
    function GetBufferedBytes: Integer; override;
    function GetLatencyMS: Integer; override;
    function GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean; override;
    procedure SetVolume(const Value: Single); override;
    procedure SetMuted(const Value: Boolean); override;
    class function EnumerateDevices: TAudioDeviceInfos; static;
    property DeviceId: string read FDeviceId write FDeviceId;
    property VolumeMode: TAudioVolumeMode read FVolumeMode write SetVolumeMode;
  end;

implementation

constructor TAudioOutputWASAPI.Create;
begin
  inherited Create;
  FVolumeMode:=avmSession;
  FApplyVolumeOnOpen:=True;
end;

procedure TAudioOutputWASAPI.AdoptWaveFormat(const Format: PWAVEFORMATEX);
var
  Extensible: PPackedWaveFormatExtensible;
begin
  SampleRate:=Format^.nSamplesPerSec;
  Channels:=Format^.nChannels;
  BitsPerSample:=Format^.wBitsPerSample;

  if Format^.wFormatTag = WAVE_FORMAT_IEEE_FLOAT then
  begin
    if Format^.wBitsPerSample <> 32 then
      raise OutputErrorClass.CreateFmt('Unsupported WASAPI float bit depth %d', [Format^.wBitsPerSample]);
    SampleType:=astFloat32
  end else
  if Format^.wFormatTag = WAVE_FORMAT_PCM then
  begin
    if Format^.wBitsPerSample <> 16 then
      raise OutputErrorClass.CreateFmt('Unsupported WASAPI PCM bit depth %d', [Format^.wBitsPerSample]);
    SampleType:=astInt16
  end else
  if Format^.wFormatTag = WAVE_FORMAT_EXTENSIBLE then
  begin
    Extensible:=PPackedWaveFormatExtensible(Format);
    if IsEqualGUID(Extensible^.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT) then
    begin
      if Format^.wBitsPerSample <> 32 then
        raise OutputErrorClass.CreateFmt('Unsupported WASAPI float bit depth %d', [Format^.wBitsPerSample]);
      SampleType:=astFloat32
    end else
    if IsEqualGUID(Extensible^.SubFormat, KSDATAFORMAT_SUBTYPE_PCM) then
    begin
      if Format^.wBitsPerSample <> 16 then
        raise OutputErrorClass.CreateFmt('Unsupported WASAPI PCM bit depth %d', [Format^.wBitsPerSample]);
      SampleType:=astInt16
    end else
      raise OutputErrorClass.Create('Unsupported WASAPI sub-format');
  end else
    raise OutputErrorClass.CreateFmt('Unsupported WASAPI format tag %d', [Format^.wFormatTag]);
end;

procedure TAudioOutputWASAPI.ApplyVolume;
var
  MuteValue: BOOL;
  VolumeValue: Single;
begin
  if NOT Assigned(FAudioClient) then
    Exit;
  if (FVolumeMode = avmEndpoint) AND NOT Assigned(FEndpointVolume) then
    raise OutputErrorClass.Create('Endpoint volume is unavailable');
  if (FVolumeMode = avmSession) AND NOT Assigned(FSimpleVolume) then
    raise OutputErrorClass.Create('This device does not expose per-application volume control.');
  if Muted then
    MuteValue:=True
  else
    MuteValue:=False;

  if Muted then
    VolumeValue:=0
  else
    VolumeValue:=Volume;

  if (FVolumeMode = avmEndpoint) AND Assigned(FEndpointVolume) then
  begin
    CheckHR(FEndpointVolume.SetMute(MuteValue, nil), 'IAudioEndpointVolume.SetMute');
    CheckHR(FEndpointVolume.SetMasterVolumeLevelScalar(VolumeValue, nil), 'IAudioEndpointVolume.SetMasterVolumeLevelScalar');
    Exit;
  end;

  if Assigned(FSimpleVolume) then
  begin
    CheckHR(FSimpleVolume.SetMute(MuteValue, nil), 'ISimpleAudioVolume.SetMute');
    CheckHR(FSimpleVolume.SetMasterVolume(VolumeValue, nil), 'ISimpleAudioVolume.SetMasterVolume');
  end;
end;

procedure TAudioOutputWASAPI.CheckHR(HR: HResult; const Action: string);
begin
  if Cardinal(HR) = $8889000A then
    raise OutputErrorClass.Create('The selected audio device is in exclusive use. Select another audio output.');
  if Failed(HR) then
    raise OutputErrorClass.CreateFmt('%s failed (0x%.8x)', [Action, Cardinal(HR)]);
end;

class procedure TAudioOutputWASAPI.CheckHRStatic(HR: HResult; const Action: string);
begin
  if Failed(HR) then
    raise EAudioOutputError.CreateFmt('%s failed (0x%.8x)', [Action, Cardinal(HR)]);
end;

procedure TAudioOutputWASAPI.Close;
begin
  if Assigned(FAudioClient) then
    FAudioClient.Stop;
  FStarted:=False;
  FEndpointVolume:=nil;
  FSimpleVolume:=nil;
  FRenderClient:=nil;
  FAudioClock:=nil;
  FClockFrequency:=0;
  FWriteEndFrame:=0;
  FLastClockFrame:=0;
  FHasWritten:=False;
  FAudioClient:=nil;
  FDevice:=nil;
  FEnumerator:=nil;
  FBufferFrameCount:=0;
  FLatencyHns:=0;
  if FCoInitialized then
  begin
    CoUninitialize;
    FCoInitialized:=False;
  end;
end;

destructor TAudioOutputWASAPI.Destroy;
begin
  Close;
  inherited Destroy;
end;

class function TAudioOutputWASAPI.EnumerateDevices: TAudioDeviceInfos;
var
  Collection: IMMDeviceCollection;
  CoInitResult: HRESULT;
  Count: UINT;
  DefaultDevice: IMMDevice;
  DefaultId: string;
  Device: IMMDevice;
  Enumerator: IMMDeviceEnumerator;
  I: UINT;
begin
  CoInitResult:=CoInitializeEx(nil, COINIT_MULTITHREADED);
  Enumerator:=nil;
  Collection:=nil;
  DefaultDevice:=nil;
  DefaultId:='';
  try
    CheckHRStatic(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, Enumerator), 'CoCreateInstance(MMDeviceEnumerator)');

    if Succeeded(Enumerator.GetDefaultAudioEndpoint(eRender, eMultimedia, DefaultDevice)) then
      DefaultId:=GetDeviceIdString(DefaultDevice);

    CheckHRStatic(Enumerator.EnumAudioEndpoints(eRender, DEVICE_STATEMASK_ALL, Collection), 'EnumAudioEndpoints');
    CheckHRStatic(Collection.GetCount(Count), 'IMMDeviceCollection.GetCount');

    SetLength(Result, Count);
    if Count > 0 then
      for I:=0 to Count - 1 do
      begin
        Device:=nil;
        CheckHRStatic(Collection.Item(I, Device), 'IMMDeviceCollection.Item');
        Result[I].Id:=GetDeviceIdString(Device);
        Result[I].FriendlyName:=AudioDeviceProperty(Device, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 14);
        Result[I].InterfaceName:=AudioDeviceProperty(Device, '{026E516E-B814-414B-83CD-856D6FEF4822}', 2);
        Result[I].DeviceDescription:=AudioDeviceProperty(Device, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 2);

        CheckHRStatic(Device.GetState(Result[I].State), 'IMMDevice.GetState');
        Result[I].StateText:=AudioDeviceStateText(Result[I].State);
        Result[I].IsDefault:=SameText(Result[I].Id, DefaultId);
      end;
  finally
    Device:=nil;
    DefaultDevice:=nil;
    Collection:=nil;
    Enumerator:=nil;
    if (CoInitResult = S_OK) OR (CoInitResult = S_FALSE) then
      CoUninitialize;
  end;
end;

function TAudioOutputWASAPI.GetBufferedBytes: Integer;
var
  PaddingFrames: UINT32;
begin
  Result:=0;
  if NOT Assigned(FAudioClient) then
    Exit;

  if Succeeded(FAudioClient.GetCurrentPadding(PaddingFrames)) then
    Result:=Integer(PaddingFrames) * BytesPerFrame;
end;

function TAudioOutputWASAPI.GetLatencyMS: Integer;
begin
  if FLatencyHns > 0 then
    Result:=Integer(FLatencyHns DIV 10000)
  else
  if (SampleRate > 0) AND (BytesPerFrame > 0) then
    Result:=(GetBufferedBytes * 1000) DIV (SampleRate * BytesPerFrame)
  else
    Result:=0;
end;

function TAudioOutputWASAPI.GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean;
var
  Position, QpcPosition: UInt64;
begin
  PlayedFrame:=0;
  WriteEndFrame:=FWriteEndFrame;
  Result:=Assigned(FAudioClock) AND (FClockFrequency > 0);
  if NOT Result then
    Exit;
  // A transient clock-query failure must freeze metering, not switch to a
  // different (submitted-frame) epoch and release queued peaks early.
  if Succeeded(FAudioClock.GetPosition(Position, QpcPosition)) then
    FLastClockFrame:=Int64((Position DIV FClockFrequency) * UInt64(SampleRate) + ((Position MOD FClockFrequency) * UInt64(SampleRate)) DIV FClockFrequency);
  PlayedFrame:=FLastClockFrame;
end;

class function TAudioOutputWASAPI.GetDeviceIdString(const Device: IMMDevice): string;
var
  DeviceId: PWideChar;
begin
  DeviceId:=nil;
  CheckHRStatic(Device.GetId(DeviceId), 'IMMDevice.GetId');
  try
    if Assigned(DeviceId) then
      Result:=DeviceId
    else
      Result:='';
  finally
    if Assigned(DeviceId) then
      CoTaskMemFree(DeviceId);
  end;
end;

function TAudioOutputWASAPI.Open(SampleRate, Channels, BitsPerSample: Integer): Boolean;
begin
  Result:=DoOpen(SampleRate, Channels, BitsPerSample, astInt16, True);
end;

function TAudioOutputWASAPI.OpenPCM(ARate, AChannels: Integer; AType: TAudioSampleType): Boolean;
var
  Bits: Integer;
begin
  if AType = astInt16 then
    Bits:=16
  else
    Bits:=32;
  if NOT (AType IN [astInt16, astFloat32]) then
    raise OutputErrorClass.Create('WASAPI expects PCM16 or float32');
  Result:=DoOpen(ARate, AChannels, Bits, AType, False);
end;

function TAudioOutputWASAPI.DoOpen(ARate, AChannels, ABits: Integer; AType: TAudioSampleType; UseMixFormat: Boolean): Boolean;
var
  Format: TAudio.Windows.TWaveFormatEx;
  MixFormat: PWaveFormatEx;
  Unknown: IUnknown;
  CoResult: HRESULT;
begin
  Close;
  MixFormat:=nil;
  try
    CoResult:=CoInitializeEx(nil, COINIT_MULTITHREADED);
    FCoInitialized:=(CoResult = S_OK) OR (CoResult = S_FALSE);
    if NOT FCoInitialized AND (CoResult <> RPC_E_CHANGED_MODE) then
      CheckHR(CoResult, 'CoInitializeEx');
    CheckHR(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, FEnumerator), 'CoCreateInstance(MMDeviceEnumerator)');
    if FDeviceId <> '' then
      CheckHR(FEnumerator.GetDevice(PWideChar(WideString(FDeviceId)), FDevice), 'GetDevice')
    else
      CheckHR(FEnumerator.GetDefaultAudioEndpoint(eRender, eMultimedia, FDevice), 'GetDefaultAudioEndpoint');
    CheckHR(FDevice.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Unknown), 'Activate(IAudioClient)');
    FAudioClient:=Unknown AS IAudioClient;
    Unknown:=nil;
    if UseMixFormat then
    begin
      CheckHR(FAudioClient.GetMixFormat(MixFormat), 'GetMixFormat');
      AdoptWaveFormat(MixFormat);
      CheckHR(FAudioClient.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, BUFFER_DURATION_HNS, 0, MixFormat, nil), 'Initialize');
    end else
    begin
      SampleRate:=ARate;
      Channels:=AChannels;
      BitsPerSample:=ABits;
      SampleType:=AType;
      ValidateFormat;
      FillChar(Format, SizeOf(Format), 0);
      Format.wFormatTag:=WAVE_FORMAT_PCM;
      if AType = astFloat32 then
        Format.wFormatTag:=WAVE_FORMAT_IEEE_FLOAT;
      Format.nSamplesPerSec:=SampleRate;
      Format.nChannels:=Channels;
      Format.wBitsPerSample:=BitsPerSample;
      Format.nBlockAlign:=BytesPerFrame;
      Format.nAvgBytesPerSec:=SampleRate * BytesPerFrame;
      CheckHR(FAudioClient.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, BUFFER_DURATION_HNS, 0, @Format, nil), 'Initialize');
    end;
    CoTaskMemFree(MixFormat);
    MixFormat:=nil;
    CheckHR(FAudioClient.GetBufferSize(FBufferFrameCount), 'GetBufferSize');
    CheckHR(FAudioClient.GetStreamLatency(FLatencyHns), 'GetStreamLatency');
    CheckHR(FAudioClient.GetService(IID_IAudioRenderClient, Unknown), 'GetService(IAudioRenderClient)');
    FRenderClient:=Unknown AS IAudioRenderClient;
    Unknown:=nil;
    if Succeeded(FAudioClient.GetService(IID_IAudioClock, Unknown)) then
    begin
      FAudioClock:=Unknown AS IAudioClock;
      Unknown:=nil;
      if Failed(FAudioClock.GetFrequency(FClockFrequency)) then
      begin
        FAudioClock:=nil;
        FClockFrequency:=0;
      end;
    end;
    if FRequireClock AND (FClockFrequency = 0) then
      raise OutputErrorClass.Create('The device does not expose an audio clock');
    Unknown:=nil;
    if Succeeded(FAudioClient.GetService(IID_ISimpleAudioVolume, Unknown)) then
      FSimpleVolume:=Unknown AS ISimpleAudioVolume;
    Unknown:=nil;
    if Succeeded(FDevice.Activate(IID_IAudioEndpointVolume, CLSCTX_ALL, nil, Unknown)) then
      FEndpointVolume:=Unknown AS IAudioEndpointVolume;
    Unknown:=nil;
    if FApplyVolumeOnOpen then
    begin
      if (FVolumeMode = avmSession) AND NOT Assigned(FSimpleVolume) then
        raise OutputErrorClass.Create('This device does not expose per-application volume control.');
      ApplyVolume;
    end;
    Result:=True;
  except
    Unknown:=nil;
    CoTaskMemFree(MixFormat);
    Close;
    raise;
  end;
end;

function TAudioOutputWASAPI.DevicePositionUs: Int64;
var
  Position, Qpc: UInt64;
begin
  Result:=-1;
  if NOT Assigned(FAudioClock) OR (FClockFrequency = 0) then
    Exit;
  if Succeeded(FAudioClock.GetPosition(Position, Qpc)) then
    Result:=Int64((Position DIV FClockFrequency) * 1000000 + ((Position MOD FClockFrequency) * 1000000) DIV FClockFrequency);
end;

function TAudioOutputWASAPI.DeviceLatencyUs: Int64;
begin
  Result:=-1;
  if FLatencyHns > 0 then
    Result:=FLatencyHns DIV 10;
end;

procedure TAudioOutputWASAPI.Pause;
begin
  if Assigned(FAudioClient) AND FStarted then
  begin
    CheckHR(FAudioClient.Stop, 'Stop');
    FStarted:=False;
  end;
end;

procedure TAudioOutputWASAPI.Flush;
var
  WasStarted: Boolean;
begin
  WasStarted:=FStarted;
  Stop;
  if WasStarted then
    Start;
end;

procedure TAudioOutputWASAPI.SetMuted(const Value: Boolean);
begin
  inherited SetMuted(Value);
  ApplyVolume;
end;

procedure TAudioOutputWASAPI.SetVolume(const Value: Single);
begin
  inherited SetVolume(Value);
  ApplyVolume;
end;

procedure TAudioOutputWASAPI.SetVolumeMode(const Value: TAudioVolumeMode);
begin
  if Assigned(FAudioClient) then
  begin
    if (Value = avmEndpoint) AND NOT Assigned(FEndpointVolume) then
      raise OutputErrorClass.Create('Endpoint volume is unavailable');
    if (Value = avmSession) AND NOT Assigned(FSimpleVolume) then
      raise OutputErrorClass.Create('Session volume is unavailable');
  end;
  FVolumeMode:=Value;
  ApplyVolume;
end;

procedure TAudioOutputWASAPI.Start;
begin
  if Assigned(FAudioClient) AND NOT FStarted then
  begin
    CheckHR(FAudioClient.Start(), 'IAudioClient.Start');
    FStarted:=True;
  end;
end;

procedure TAudioOutputWASAPI.Stop;
begin
  Pause;
  if Assigned(FAudioClient) then
    CheckHR(FAudioClient.Reset, 'Reset');
  FWriteEndFrame:=0;
  FLastClockFrame:=0;
  FHasWritten:=False;
end;

function TAudioOutputWASAPI.Write(Buffer: PByte; ByteCount: Integer): Integer;
var
  AvailableFrames: UINT32;
  DataBuffer: PByte;
  PaddingFrames: UINT32;
  RemainingFrames: UINT32;
  TotalFrames: UINT32;
  WriteFrames: UINT32;
  WrittenFrames: UINT32;
  ClockFrame, IgnoredEnd: Int64;
begin
  Result:=0;
  if NOT Assigned(FAudioClient) OR NOT Assigned(FRenderClient) OR NOT Assigned(Buffer) OR (ByteCount <= 0) then
    Exit;

  if BytesPerFrame <= 0 then
    Exit;

  TotalFrames:=ByteCount DIV BytesPerFrame;
  WrittenFrames:=0;

  while WrittenFrames < TotalFrames do
  begin
    if Assigned(StopEvent) AND (StopEvent.WaitFor(0) = wrSignaled) then
      Break;
    CheckHR(FAudioClient.GetCurrentPadding(PaddingFrames), 'IAudioClient.GetCurrentPadding');
    // Some drivers advance the clock through underrun silence; others stall
    // at the last submitted sample. Re-anchor only when it has run ahead.
    // Initial playback starts at clock zero.
    if (PaddingFrames = 0) AND GetMeterPosition(ClockFrame, IgnoredEnd) then
    begin
      if FHasWritten AND (ClockFrame > FWriteEndFrame) then
        FWriteEndFrame:=ClockFrame + (FLatencyHns * SampleRate) DIV 10000000
      else
      if NOT FHasWritten then
        FWriteEndFrame:=ClockFrame;
    end;
    AvailableFrames:=FBufferFrameCount - PaddingFrames;
    if AvailableFrames = 0 then
    begin
      if NOT BlockingWrites then
        Break;
      if WaitCancelled(2) then
        Break;
      Continue;
    end;

    RemainingFrames:=TotalFrames - WrittenFrames;
    if RemainingFrames < AvailableFrames then
      WriteFrames:=RemainingFrames
    else
      WriteFrames:=AvailableFrames;

    CheckHR(FRenderClient.GetBuffer(WriteFrames, DataBuffer), 'IAudioRenderClient.GetBuffer');
    Move(Buffer[Integer(WrittenFrames) * BytesPerFrame], DataBuffer^, Integer(WriteFrames) * BytesPerFrame);
    CheckHR(FRenderClient.ReleaseBuffer(WriteFrames, 0), 'IAudioRenderClient.ReleaseBuffer');

    Inc(FWriteEndFrame, WriteFrames);
    FHasWritten:=True;

    Inc(WrittenFrames, WriteFrames);
  end;

  Result:=Integer(WrittenFrames) * BytesPerFrame;
end;

end.
