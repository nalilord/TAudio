unit TAudio.Types;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

type
  TAudioSampleType = (astInt16, astFloat32, astUInt8, astInt32);
  TAudioVolumeMode = (avmSession, avmEndpoint);
  TAudioDeviceInfo = record
    Id: string;
    FriendlyName: string;
    InterfaceName: string;
    DeviceDescription: string;
    State: Cardinal;
    StateText: string;
    IsDefault: Boolean;
  end;
  TAudioDeviceInfos = array of TAudioDeviceInfo;

implementation
end.
