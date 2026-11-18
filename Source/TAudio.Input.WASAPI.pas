unit TAudio.Input.WASAPI;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$POINTERMATH ON}

{
  WASAPI shared-mode capture: capture endpoints (microphone, line in, capture
  cards) and loopback of render endpoints (what a device plays).

  Each packet's CaptureTimeUs is WASAPI's QPC position for its first frame, so it
  is directly comparable with TAudio.Clock.AudioMonotonicUs.

  Loopback of an idle render endpoint delivers no packets at all. With
  KeepLoopbackAlive (default) the input plays silence on the same endpoint, so
  loopback packets keep arriving with real timestamps.

  Event-driven where the endpoint supports it, otherwise polled every 5 ms.
  The capture thread calls OnData; see TAudio.Input.
}

interface

uses
{$IFDEF FPC}
  Windows, ActiveX, SysUtils, Classes, SyncObjs,
{$ELSE}
  Winapi.Windows, Winapi.ActiveX, System.SysUtils, System.Classes, System.SyncObjs,
{$ENDIF}
  TAudio.Types, TAudio.Windows, TAudio.Clock, TAudio.Input;

type
  TAudioInputWASAPI = class;

  TAudioInputWASAPIThread = class(TThread)
  private
    FOwner: TAudioInputWASAPI;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioInputWASAPI);
  end;

  TAudioInputWASAPI = class(TAudioInput)
  private
    FDeviceId: string;
    FLoopback: Boolean;
    FKeepLoopbackAlive: Boolean;
    FBufferMs: Integer;
    FCoInitialized: Boolean;
    FEnumerator: IMMDeviceEnumerator;
    FDevice: IMMDevice;
    FAudioClient: IAudioClient;
    FCaptureClient: IAudioCaptureClient;
    FKeepAliveClient: IAudioClient;
    FKeepAliveRender: IAudioRenderClient;
    FKeepAliveFrames: UINT32;
    FEvent: TEvent;
    FEventDriven: Boolean;
    FThread: TAudioInputWASAPIThread;
    FStopping: Boolean;
    FFirstPacket: Boolean;
    FSilence: TBytes;
    FDeviceName: string;
    procedure CheckHR(HR: HResult; const Action: string);
    procedure AdoptWaveFormat(Format: PWaveFormatEx);
    procedure OpenKeepAlive(Format: PWaveFormatEx);
    procedure FeedKeepAlive;
    procedure Drain;
    procedure CaptureLoop;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Open; override;
    procedure Start; override;
    procedure Stop; override;
    procedure Close; override;
    // Capture endpoints, or render endpoints when Loopback is True.
    class function EnumerateDevices(Loopback: Boolean = False): TAudioDeviceInfos; static;
    // Empty: the default capture endpoint (or default render endpoint for loopback).
    property DeviceId: string read FDeviceId write FDeviceId;
    property Loopback: Boolean read FLoopback write FLoopback;
    property KeepLoopbackAlive: Boolean read FKeepLoopbackAlive write FKeepLoopbackAlive;
    // Shared-mode buffer duration requested from WASAPI.
    property BufferMs: Integer read FBufferMs write FBufferMs;
    property EventDriven: Boolean read FEventDriven;
    property DeviceName: string read FDeviceName;
  end;

implementation

type
  PPackedWaveFormatExtensible = ^TPackedWaveFormatExtensible;
  TPackedWaveFormatExtensible = packed record
    Format: TWaveFormatEx;
    wValidBitsPerSample: Word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

function DeviceIdString(const Device: IMMDevice): string;
var
  Id: PWideChar;
begin
  Result:='';
  Id:=nil;
  if Succeeded(Device.GetId(Id)) AND (Id <> nil) then
  begin
    Result:=Id;
    CoTaskMemFree(Id);
  end;
end;

{ TAudioInputWASAPIThread }

constructor TAudioInputWASAPIThread.Create(AOwner: TAudioInputWASAPI);
begin
  FOwner:=AOwner;
  inherited Create(False);
end;

procedure TAudioInputWASAPIThread.Execute;
var
  CoResult: HResult;
begin
  CoResult:=CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    try
      FOwner.CaptureLoop;
    except
      on E: Exception do
        FOwner.DeliverError(E.Message);
    end;
  finally
    if (CoResult = S_OK) OR (CoResult = S_FALSE) then
      CoUninitialize;
  end;
end;

{ TAudioInputWASAPI }

constructor TAudioInputWASAPI.Create;
begin
  inherited Create;
  FKeepLoopbackAlive:=True;
  FBufferMs:=100;
end;

destructor TAudioInputWASAPI.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TAudioInputWASAPI.CheckHR(HR: HResult; const Action: string);
begin
  if Cardinal(HR) = $8889000A then
    raise EAudioInputError.Create('The selected audio device is in exclusive use.');
  if Failed(HR) then
    raise EAudioInputError.CreateFmt('%s failed (0x%.8x)', [Action, Cardinal(HR)]);
end;

procedure TAudioInputWASAPI.AdoptWaveFormat(Format: PWaveFormatEx);
var
  IsFloat: Boolean;
begin
  SampleRate:=Format^.nSamplesPerSec;
  Channels:=Format^.nChannels;
  BitsPerSample:=Format^.wBitsPerSample;
  IsFloat:=Format^.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
  if Format^.wFormatTag = WAVE_FORMAT_EXTENSIBLE then
    IsFloat:=IsEqualGUID(PPackedWaveFormatExtensible(Format)^.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT)
  else if (Format^.wFormatTag <> WAVE_FORMAT_PCM) AND NOT IsFloat then
    raise EAudioInputError.CreateFmt('Unsupported WASAPI format tag %d', [Format^.wFormatTag]);
  if IsFloat AND (BitsPerSample = 32) then
    SampleType:=astFloat32
  else if NOT IsFloat AND (BitsPerSample = 16) then
    SampleType:=astInt16
  else if NOT IsFloat AND (BitsPerSample = 32) then
    SampleType:=astInt32
  else
  begin
    if IsFloat then
      raise EAudioInputError.CreateFmt('Unsupported WASAPI mix format: %d-bit float', [BitsPerSample]);
    raise EAudioInputError.CreateFmt('Unsupported WASAPI mix format: %d-bit PCM', [BitsPerSample]);
  end;
end;

procedure TAudioInputWASAPI.Open;
var
  CoResult: HResult;
  MixFormat: PWaveFormatEx;
  Unknown: IUnknown;
  Flags: DWORD;
  HR: HResult;
  Duration: Int64;
begin
  Close;
  MixFormat:=nil;
  try
    CoResult:=CoInitializeEx(nil, COINIT_MULTITHREADED);
    FCoInitialized:=(CoResult = S_OK) OR (CoResult = S_FALSE);
    if NOT FCoInitialized AND (CoResult <> RPC_E_CHANGED_MODE) then
      CheckHR(CoResult, 'CoInitializeEx');
    CheckHR(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, FEnumerator),
      'CoCreateInstance(MMDeviceEnumerator)');
    if FDeviceId <> '' then
      CheckHR(FEnumerator.GetDevice(PWideChar(WideString(FDeviceId)), FDevice), 'GetDevice')
    else if FLoopback then
      CheckHR(FEnumerator.GetDefaultAudioEndpoint(eRender, eMultimedia, FDevice), 'GetDefaultAudioEndpoint(render)')
    else
      CheckHR(FEnumerator.GetDefaultAudioEndpoint(eCapture, eMultimedia, FDevice), 'GetDefaultAudioEndpoint(capture)');
    FDeviceName:=AudioDeviceProperty(FDevice, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 14);
    CheckHR(FDevice.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Unknown), 'Activate(IAudioClient)');
    FAudioClient:=Unknown AS IAudioClient;
    Unknown:=nil;
    CheckHR(FAudioClient.GetMixFormat(MixFormat), 'GetMixFormat');
    AdoptWaveFormat(MixFormat);

    Duration:=Int64(FBufferMs) * 10000;
    Flags:=AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    if FLoopback then
      Flags:=Flags OR AUDCLNT_STREAMFLAGS_LOOPBACK;
    HR:=FAudioClient.Initialize(AUDCLNT_SHAREMODE_SHARED, Flags, Duration, 0, MixFormat, nil);
    FEventDriven:=Succeeded(HR);
    if NOT FEventDriven then
    begin
      // Older systems reject event callbacks for loopback: use a fresh client and poll.
      FAudioClient:=nil;
      CheckHR(FDevice.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Unknown), 'Activate(IAudioClient)');
      FAudioClient:=Unknown AS IAudioClient;
      Unknown:=nil;
      CheckHR(FAudioClient.Initialize(AUDCLNT_SHAREMODE_SHARED, Flags AND NOT AUDCLNT_STREAMFLAGS_EVENTCALLBACK, Duration, 0,
        MixFormat, nil), 'Initialize');
    end;
    FEvent:=TEvent.Create(nil, False, False, '');
    if FEventDriven then
      CheckHR(FAudioClient.SetEventHandle(FEvent.Handle), 'SetEventHandle');
    CheckHR(FAudioClient.GetService(IID_IAudioCaptureClient, Unknown), 'GetService(IAudioCaptureClient)');
    FCaptureClient:=Unknown AS IAudioCaptureClient;
    Unknown:=nil;
    if FLoopback AND FKeepLoopbackAlive then
      OpenKeepAlive(MixFormat);
    CoTaskMemFree(MixFormat);
    MixFormat:=nil;
  except
    Unknown:=nil;
    if MixFormat <> nil then
      CoTaskMemFree(MixFormat);
    Close;
    raise;
  end;
end;

procedure TAudioInputWASAPI.OpenKeepAlive(Format: PWaveFormatEx);
var
  Unknown: IUnknown;
begin
  CheckHR(FDevice.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Unknown), 'Activate(IAudioClient keep-alive)');
  FKeepAliveClient:=Unknown AS IAudioClient;
  Unknown:=nil;
  CheckHR(FKeepAliveClient.Initialize(AUDCLNT_SHAREMODE_SHARED, 0, 1000000, 0, Format, nil), 'Initialize(keep-alive)');
  CheckHR(FKeepAliveClient.GetBufferSize(FKeepAliveFrames), 'GetBufferSize(keep-alive)');
  CheckHR(FKeepAliveClient.GetService(IID_IAudioRenderClient, Unknown), 'GetService(IAudioRenderClient)');
  FKeepAliveRender:=Unknown AS IAudioRenderClient;
end;

procedure TAudioInputWASAPI.FeedKeepAlive;
const
  AUDCLNT_BUFFERFLAGS_SILENT_RENDER = 2;
var
  Padding: UINT32;
  Data: PByte;
  Free: UINT32;
begin
  if FKeepAliveRender = nil then
    Exit;
  if Failed(FKeepAliveClient.GetCurrentPadding(Padding)) then
    Exit;
  Free:=FKeepAliveFrames - Padding;
  if Free = 0 then
    Exit;
  if Succeeded(FKeepAliveRender.GetBuffer(Free, Data)) then
    FKeepAliveRender.ReleaseBuffer(Free, AUDCLNT_BUFFERFLAGS_SILENT_RENDER);
end;

procedure TAudioInputWASAPI.Start;
begin
  if FAudioClient = nil then
    Open;
  if FThread <> nil then
    Exit;
  if FKeepAliveClient <> nil then
  begin
    FeedKeepAlive;
    CheckHR(FKeepAliveClient.Start, 'Start(keep-alive)');
  end;
  CheckHR(FAudioClient.Start, 'IAudioClient.Start');
  FStopping:=False;
  FFirstPacket:=True;
  FThread:=TAudioInputWASAPIThread.Create(Self);
end;

procedure TAudioInputWASAPI.Stop;
begin
  if FThread = nil then
    Exit;
  FStopping:=True;
  FEvent.SetEvent;
  FThread.WaitFor;
  FreeAndNil(FThread);
  if FAudioClient <> nil then
    FAudioClient.Stop;
  if FKeepAliveClient <> nil then
    FKeepAliveClient.Stop;
end;

procedure TAudioInputWASAPI.Close;
begin
  Stop;
  FCaptureClient:=nil;
  FKeepAliveRender:=nil;
  FKeepAliveClient:=nil;
  FAudioClient:=nil;
  FDevice:=nil;
  FEnumerator:=nil;
  FreeAndNil(FEvent);
  if FCoInitialized then
  begin
    CoUninitialize;
    FCoInitialized:=False;
  end;
end;

procedure TAudioInputWASAPI.Drain;
var
  Next, Frames: UINT32;
  Data: PByte;
  Flags: DWORD;
  DevicePosition, QpcPosition: UInt64;
  Packet: TAudioInputPacket;
  HR: HResult;
  Bytes: Integer;
begin
  while NOT FStopping do
  begin
    HR:=FCaptureClient.GetNextPacketSize(Next);
    if HR = AUDCLNT_E_DEVICE_INVALIDATED then
      raise EAudioInputError.Create('The audio capture device was removed or reconfigured');
    CheckHR(HR, 'GetNextPacketSize');
    if Next = 0 then
      Exit;
    HR:=FCaptureClient.GetBuffer(Data, Frames, Flags, @DevicePosition, @QpcPosition);
    if HR = AUDCLNT_S_BUFFER_EMPTY then
      Exit;
    if HR = AUDCLNT_E_DEVICE_INVALIDATED then
      raise EAudioInputError.Create('The audio capture device was removed or reconfigured');
    CheckHR(HR, 'IAudioCaptureClient.GetBuffer');
    try
      Packet:=Default(TAudioInputPacket);
      Packet.Frames:=Frames;
      Packet.DevicePosition:=Int64(DevicePosition);
      Packet.CaptureTimeUs:=AudioQpcHnsToUs(QpcPosition);
      // WASAPI flags the first packet after Start as a discontinuity; that is not a glitch.
      Packet.Discontinuity:=((Flags AND AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) <> 0) AND NOT FFirstPacket;
      FFirstPacket:=False;
      Packet.Silent:=(Flags AND AUDCLNT_BUFFERFLAGS_SILENT) <> 0;
      Packet.TimestampError:=(Flags AND AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) <> 0;
      if Packet.TimestampError then
        Packet.CaptureTimeUs:=AudioMonotonicUs;
      if Packet.Silent OR (Data = nil) then
      begin
        Bytes:=Integer(Frames) * BytesPerFrame;
        if Length(FSilence) < Bytes then
        begin
          SetLength(FSilence, Bytes);
          FillChar(FSilence[0], Bytes, 0);
        end;
        Packet.Data:=@FSilence[0];
      end else
        Packet.Data:=Data;
      DeliverPacket(Packet);
    finally
      FCaptureClient.ReleaseBuffer(Frames);
    end;
  end;
end;

procedure TAudioInputWASAPI.CaptureLoop;
var
  Wait: Cardinal;
begin
  if FEventDriven then
    Wait:=100
  else
    Wait:=5;
  while NOT FStopping do
  begin
    FEvent.WaitFor(Wait);
    if FStopping then
      Break;
    FeedKeepAlive;
    Drain;
  end;
end;

class function TAudioInputWASAPI.EnumerateDevices(Loopback: Boolean): TAudioDeviceInfos;
var
  Collection: IMMDeviceCollection;
  CoResult: HResult;
  Count, I: UINT;
  Device, DefaultDevice: IMMDevice;
  Enumerator: IMMDeviceEnumerator;
  DefaultId: string;
  Flow: Integer;
begin
  Result:=nil;
  if Loopback then
    Flow:=eRender
  else
    Flow:=eCapture;
  CoResult:=CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    if Failed(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, Enumerator)) then
      raise EAudioInputError.Create('CoCreateInstance(MMDeviceEnumerator) failed');
    DefaultId:='';
    if Succeeded(Enumerator.GetDefaultAudioEndpoint(Flow, eMultimedia, DefaultDevice)) then
      DefaultId:=DeviceIdString(DefaultDevice);
    if Failed(Enumerator.EnumAudioEndpoints(Flow, DEVICE_STATEMASK_ALL, Collection)) OR Failed(Collection.GetCount(Count)) then
      raise EAudioInputError.Create('EnumAudioEndpoints failed');
    SetLength(Result, Count);
    if Count > 0 then
      for I:=0 to Count - 1 do
      begin
        Device:=nil;
        if Failed(Collection.Item(I, Device)) then
          Continue;
        Result[I].Id:=DeviceIdString(Device);
        Result[I].FriendlyName:=AudioDeviceProperty(Device, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 14);
        Result[I].InterfaceName:=AudioDeviceProperty(Device, '{026E516E-B814-414B-83CD-856D6FEF4822}', 2);
        Result[I].DeviceDescription:=AudioDeviceProperty(Device, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 2);
        Device.GetState(Result[I].State);
        Result[I].StateText:=AudioDeviceStateText(Result[I].State);
        Result[I].IsDefault:=SameText(Result[I].Id, DefaultId);
      end;
  finally
    Device:=nil;
    DefaultDevice:=nil;
    Collection:=nil;
    Enumerator:=nil;
    if (CoResult = S_OK) OR (CoResult = S_FALSE) then
      CoUninitialize;
  end;
end;

end.
