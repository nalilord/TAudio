unit TAudio.Input;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{
  PCM capture contract, the counterpart of TAudio.Output.

  A started input delivers packets on its own capture thread through OnData.
  Each packet carries the interleaved frames in the negotiated format, the
  device's own frame position, and the reference time at which its first frame
  was recorded (CaptureTimeUs, in the TAudio.Clock.AudioMonotonicUs timebase).
  Feed packets to TAudioClockSync to lock the device clock to that reference.

  Packet data is only valid during the callback. OnData must be fast; copy and
  hand off. OnError reports a fatal capture error (e.g. the device was removed);
  the capture thread then stops.
}

interface

uses
{$IFDEF FPC}
  SysUtils, SyncObjs,
{$ELSE}
  System.SysUtils, System.SyncObjs,
{$ENDIF}
  TAudio.Types;

type
  EAudioInputError = class(Exception);

  TAudioInputPacket = record
    // Interleaved frames; for Silent packets the data is zero-filled.
    Data: PByte;
    Frames: Integer;
    // The device's frame counter at the first frame of the packet.
    DevicePosition: Int64;
    // Reference time (us, TAudio.Clock timebase) of the first frame.
    CaptureTimeUs: Int64;
    // The device reported a gap before this packet (glitch, overrun).
    Discontinuity: Boolean;
    Silent: Boolean;
    // The device could not timestamp this packet; CaptureTimeUs is an estimate.
    TimestampError: Boolean;
  end;

  TAudioInputDataEvent = procedure(Sender: TObject; const Packet: TAudioInputPacket) of object;
  TAudioInputErrorEvent = procedure(Sender: TObject; const Message: string) of object;

  TAudioInput = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBitsPerSample: Integer;
    FSampleType: TAudioSampleType;
    FOnData: TAudioInputDataEvent;
    FOnError: TAudioInputErrorEvent;
  protected
    FPackets: Int64;
    FFrames: Int64;
    FDiscontinuities: Int64;
    FTimestampErrors: Int64;
    FLastError: string;
    procedure DeliverPacket(const Packet: TAudioInputPacket);
    procedure DeliverError(const Message: string);
  public
    constructor Create; virtual;
    // Opens the device in its shared mix format; read SampleRate/Channels/SampleType afterwards.
    procedure Open; virtual; abstract;
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    procedure Close; virtual; abstract;
    function BytesPerFrame: Integer;
    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property BitsPerSample: Integer read FBitsPerSample write FBitsPerSample;
    property SampleType: TAudioSampleType read FSampleType write FSampleType;
    property OnData: TAudioInputDataEvent read FOnData write FOnData;
    property OnError: TAudioInputErrorEvent read FOnError write FOnError;
    property Packets: Int64 read FPackets;
    property Frames: Int64 read FFrames;
    property Discontinuities: Int64 read FDiscontinuities;
    property TimestampErrors: Int64 read FTimestampErrors;
    property LastError: string read FLastError;
  end;

implementation

constructor TAudioInput.Create;
begin
  inherited Create;
  FSampleType:=astFloat32;
end;

function TAudioInput.BytesPerFrame: Integer;
begin
  Result:=FChannels * (FBitsPerSample DIV 8);
end;

procedure TAudioInput.DeliverPacket(const Packet: TAudioInputPacket);
begin
  Inc(FPackets);
  Inc(FFrames, Packet.Frames);
  if Packet.Discontinuity then
    Inc(FDiscontinuities);
  if Packet.TimestampError then
    Inc(FTimestampErrors);
  if Assigned(FOnData) then
    FOnData(Self, Packet);
end;

procedure TAudioInput.DeliverError(const Message: string);
begin
  FLastError:=Message;
  if Assigned(FOnError) then
    FOnError(Self, Message);
end;

end.
