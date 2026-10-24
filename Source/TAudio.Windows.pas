unit TAudio.Windows;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$ALIGN 8}

interface

uses
{$IFDEF FPC}
  Windows, ActiveX;
{$ELSE}
  Winapi.Windows, Winapi.ActiveX;
{$ENDIF}

const
  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IMMDeviceEnumerator: TGUID = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
  IID_IAudioClient: TGUID = '{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}';
  IID_IAudioRenderClient: TGUID = '{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}';
  IID_IAudioClock: TGUID = '{CD63314F-3FBA-4A1B-812C-EF96358728E7}';

  E_RENDER = 0;
  ER_MULTIMEDIA = 1;
  AUDCLNT_SHAREMODE_SHARED = 0;
  WAVE_FORMAT_PCM = 1;
  WAVE_FORMAT_IEEE_FLOAT = 3;
  RPC_E_CHANGED_MODE = HResult($80010106);
  BUFFER_DURATION_HNS = 200 * 10000;

type
  PWaveFormatEx = ^TWaveFormatEx;
  TWaveFormatEx = packed record
    wFormatTag: Word;
    nChannels: Word;
    nSamplesPerSec: DWORD;
    nAvgBytesPerSec: DWORD;
    nBlockAlign: Word;
    wBitsPerSample: Word;
    cbSize: Word;
  end;

  IMMDevice = interface;
  IMMDeviceCollection = interface;
  IAudioPropertyStore = interface;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: Integer; dwStateMask: DWORD; out ppDevices: IMMDeviceCollection): HResult; stdcall;
    function GetDefaultAudioEndpoint(dataFlow: Integer; role: Integer; out ppEndpoint: IMMDevice): HResult; stdcall;
    function GetDevice(pwstrId: PWideChar; out ppDevice: IMMDevice): HResult; stdcall;
    function RegisterEndpointNotificationCallback(pClient: IUnknown): HResult; stdcall;
    function UnregisterEndpointNotificationCallback(pClient: IUnknown): HResult; stdcall;
  end;

  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD; pActivationParams: Pointer; out ppInterface: IUnknown): HResult; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties: IAudioPropertyStore): HResult; stdcall;
    function GetId(out ppstrId: PWideChar): HResult; stdcall;
    function GetState(out pdwState: DWORD): HResult; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4C32-B178-C2F568A703B2}']
    function Initialize(ShareMode: Integer; StreamFlags: DWORD; hnsBufferDuration: Int64;
      hnsPeriodicity: Int64; pFormat: PWaveFormatEx; AudioSessionGuid: PGUID): HResult; stdcall;
    function GetBufferSize(out pNumBufferFrames: UINT32): HResult; stdcall;
    function GetStreamLatency(out phnsLatency: Int64): HResult; stdcall;
    function GetCurrentPadding(out pNumPaddingFrames: UINT32): HResult; stdcall;
    function IsFormatSupported(ShareMode: Integer; pFormat: PWaveFormatEx;
      out ppClosestMatch: PWaveFormatEx): HResult; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWaveFormatEx): HResult; stdcall;
    function GetDevicePeriod(out phnsDefaultDevicePeriod: Int64; out phnsMinimumDevicePeriod: Int64): HResult; stdcall;
    function Start: HResult; stdcall;
    function Stop: HResult; stdcall;
    function Reset: HResult; stdcall;
    function SetEventHandle(eventHandle: THandle): HResult; stdcall;
    function GetService(const riid: TGUID; out ppv: IUnknown): HResult; stdcall;
  end;

  IAudioRenderClient = interface(IUnknown)
    ['{F294ACFC-3146-4483-A7BF-ADDCA7C260E2}']
    function GetBuffer(NumFramesRequested: UINT32; out ppData: PByte): HResult; stdcall;
    function ReleaseBuffer(NumFramesWritten: UINT32; dwFlags: DWORD): HResult; stdcall;
  end;

  IAudioClock = interface(IUnknown)
    ['{CD63314F-3FBA-4A1B-812C-EF96358728E7}']
    function GetFrequency(out pu64Frequency: UInt64): HResult; stdcall;
    function GetPosition(out pu64Position: UInt64; out pu64QPCPosition: UInt64): HResult; stdcall;
    function GetCharacteristics(out pdwCharacteristics: DWORD): HResult; stdcall;
  end;

  TAudioPropertyKey = record
    FmtId: TGUID;
    Pid: Cardinal;
  end;
  TAudioPropVariant = record
    Vt, Reserved1, Reserved2, Reserved3: Word;
    case Integer of
      0: (Text: PWideChar);
      1: (Number: Int64);
      2: (Count: Cardinal; Data: Pointer);
  end;
  IAudioPropertyStore = interface(IUnknown)
    ['{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}']
    function GetCount(out Count: Cardinal): HResult; stdcall;
    function GetAt(Index: Cardinal; out Key: TAudioPropertyKey): HResult; stdcall;
    function GetValue(const Key: TAudioPropertyKey; out Value: TAudioPropVariant): HResult; stdcall;
    function SetValue(const Key: TAudioPropertyKey; const Value: TAudioPropVariant): HResult; stdcall;
    function Commit: HResult; stdcall;
  end;
  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-C0A3B5A8A9B1}']
    function GetCount(out Count: UINT): HResult; stdcall;
    function Item(Index: UINT; out Device: IMMDevice): HResult; stdcall;
  end;
  ISimpleAudioVolume = interface(IUnknown)
    ['{87CE5498-68D6-44E5-9215-6DA47EF883D8}']
    function SetMasterVolume(Level: Single; Context: PGUID): HResult; stdcall;
    function GetMasterVolume(out Level: Single): HResult; stdcall;
    function SetMute(Muted: BOOL; Context: PGUID): HResult; stdcall;
    function GetMute(out Muted: BOOL): HResult; stdcall;
  end;
  IAudioEndpointVolume = interface(IUnknown)
    ['{5CDF2C82-841E-4546-9722-0CF74078229A}']
    function RegisterControlChangeNotify(Notify: IUnknown): HResult; stdcall;
    function UnregisterControlChangeNotify(Notify: IUnknown): HResult; stdcall;
    function GetChannelCount(out Count: UINT): HResult; stdcall;
    function SetMasterVolumeLevel(Level: Single; Context: PGUID): HResult; stdcall;
    function SetMasterVolumeLevelScalar(Level: Single; Context: PGUID): HResult; stdcall;
    function GetMasterVolumeLevel(out Level: Single): HResult; stdcall;
    function GetMasterVolumeLevelScalar(out Level: Single): HResult; stdcall;
    function SetChannelVolumeLevel(Channel: UINT; Level: Single; Context: PGUID): HResult; stdcall;
    function SetChannelVolumeLevelScalar(Channel: UINT; Level: Single; Context: PGUID): HResult; stdcall;
    function GetChannelVolumeLevel(Channel: UINT; out Level: Single): HResult; stdcall;
    function GetChannelVolumeLevelScalar(Channel: UINT; out Level: Single): HResult; stdcall;
    function SetMute(Muted: BOOL; Context: PGUID): HResult; stdcall;
    function GetMute(out Muted: BOOL): HResult; stdcall;
  end;

const
  IID_ISimpleAudioVolume: TGUID = '{87CE5498-68D6-44E5-9215-6DA47EF883D8}';
  IID_IAudioEndpointVolume: TGUID = '{5CDF2C82-841E-4546-9722-0CF74078229A}';
  KSDATAFORMAT_SUBTYPE_PCM: TGUID = '{00000001-0000-0010-8000-00AA00389B71}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: TGUID = '{00000003-0000-0010-8000-00AA00389B71}';
  WAVE_FORMAT_EXTENSIBLE = $FFFE;
  eRender = E_RENDER;
  eMultimedia = ER_MULTIMEDIA;
  DEVICE_STATEMASK_ALL = $F;

function AudioDeviceProperty(const Device: IMMDevice; const FmtId: string;
  Pid: Cardinal): string;
function AudioDeviceStateText(State: Cardinal): string;

implementation

uses
{$IFDEF FPC}
  SysUtils;
{$ELSE}
  System.SysUtils;
{$ENDIF}

function ClearAudioPropVariant(var Value: TAudioPropVariant): HResult; stdcall;
  external 'ole32.dll' name 'PropVariantClear';

function AudioDeviceProperty(const Device: IMMDevice; const FmtId: string;
  Pid: Cardinal): string;
var
  Store: IAudioPropertyStore;
  Key: TAudioPropertyKey;
  Value: TAudioPropVariant;
begin
  Result:='';
  if Failed(Device.OpenPropertyStore(0, Store)) then
    Exit;
  Key.FmtId:=StringToGUID(FmtId);
  Key.Pid:=Pid;
  FillChar(Value, SizeOf(Value), 0);
  try
    if Succeeded(Store.GetValue(Key, Value)) AND (Value.Vt = 31) AND
      (Value.Text <> nil) then
      Result:=Value.Text;
  finally
    ClearAudioPropVariant(Value);
  end;
end;

function AudioDeviceStateText(State: Cardinal): string;
begin
  case State of
    1: Result:='Active';
    2: Result:='Disabled';
    4: Result:='Not present';
    8: Result:='Unplugged';
    else Result:='Unknown';
  end;
end;

end.
