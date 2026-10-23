unit TAudio.Output;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, SyncObjs, TAudio.Types;
{$ELSE}
  System.SysUtils, System.SyncObjs, System.Diagnostics, TAudio.Types;
{$ENDIF}

type
  TAudioSampleType = TAudio.Types.TAudioSampleType;

  EAudioOutputError = class(Exception);
  TAudioOutputErrorClass = class of EAudioOutputError;

  TAudioOutput = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBitsPerSample: Integer;
    FSampleType: TAudioSampleType;
    FVolume: Single;
    FMuted: Boolean;
    FStopEvent: TEvent;
    FBlockingWrites: Boolean;
    FOutputErrorClass: TAudioOutputErrorClass;
    procedure SetOutputErrorClass(Value: TAudioOutputErrorClass);
  protected
    function Cancelled: Boolean;
    function WaitCancelled(TimeoutMS: Cardinal): Boolean;
    procedure ValidateFormat;
    function ClampVolume(const Value: Single): Single;
  public
    constructor Create; virtual;

    function Open(SampleRate, Channels, BitsPerSample: Integer): Boolean; virtual; abstract;
    procedure Close; virtual; abstract;
    procedure Start; virtual; abstract;
    procedure Stop; virtual; abstract;
    function Write(Buffer: PByte; ByteCount: Integer): Integer; virtual; abstract;
    function GetBufferedBytes: Integer; virtual; abstract;
    function QueuedBytes64: Int64; virtual;
    function GetLatencyMS: Integer; virtual; abstract;
    // Positions in output sample frames, on the same timeline. False lets
    // legacy backends use submitted frames minus their current buffer padding.
    function GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean; virtual;
    procedure SetVolume(const Value: Single); virtual;
    procedure SetMuted(const Value: Boolean); virtual;
    function BytesPerFrame: Integer;
    procedure Pause; virtual;
    procedure Flush; virtual;
    function DevicePositionUs: Int64; virtual;
    function DeviceLatencyUs: Int64; virtual;
    function WaitUntilDrained(TimeoutMS: Cardinal): Boolean; virtual;

    property SampleRate: Integer read FSampleRate write FSampleRate;
    property Channels: Integer read FChannels write FChannels;
    property BitsPerSample: Integer read FBitsPerSample write FBitsPerSample;
    property SampleType: TAudioSampleType read FSampleType write FSampleType;
    property Volume: Single read FVolume;
    property Muted: Boolean read FMuted;
    property BlockingWrites: Boolean read FBlockingWrites write FBlockingWrites;
    property OutputErrorClass: TAudioOutputErrorClass read FOutputErrorClass write SetOutputErrorClass;
    // Borrowed event: caller keeps it alive until this output is closed.
    property StopEvent: TEvent read FStopEvent write FStopEvent;
  end;

  // Paced sink used by automated playback checks without touching audio devices.
  TAudioOutputNull = class(TAudioOutput)
  public
    function Open(ARate, AChannels, ABits: Integer): Boolean; override;
    procedure Close; override;
    procedure Start; override;
    procedure Stop; override;
    function Write(Buffer: PByte; ByteCount: Integer): Integer; override;
    function GetBufferedBytes: Integer; override;
    function GetLatencyMS: Integer; override;
  end;

const
  astInt16 = TAudio.Types.astInt16;
  astFloat32 = TAudio.Types.astFloat32;
  astUInt8 = TAudio.Types.astUInt8;
  astInt32 = TAudio.Types.astInt32;

implementation

function AudioMonotonicMS: UInt64;
{$IFNDEF FPC}var Ticks, Frequency: Int64;{$ENDIF}
begin
{$IFDEF FPC}
  Result := GetTickCount64;
{$ELSE}
  Ticks := TStopwatch.GetTimeStamp;
  Frequency := TStopwatch.Frequency;
  Result := UInt64(Ticks div Frequency) * 1000 +
    UInt64((Ticks mod Frequency) * 1000 div Frequency);
{$ENDIF}
end;

function TAudioOutput.Cancelled: Boolean;
begin
  Result := Assigned(StopEvent) and (StopEvent.WaitFor(0) = wrSignaled);
end;

function TAudioOutput.WaitCancelled(TimeoutMS: Cardinal): Boolean;
begin
  if Assigned(StopEvent) then
    Result := StopEvent.WaitFor(TimeoutMS) = wrSignaled
  else
  begin
    Sleep(TimeoutMS);
    Result := False;
  end;
end;

procedure TAudioOutput.ValidateFormat;
var ExpectedBits: Integer;
begin
  case SampleType of
    astUInt8: ExpectedBits := 8;
    astInt16: ExpectedBits := 16;
  else ExpectedBits := 32;
  end;
  if (SampleRate <= 0) or (Channels <= 0) or (Channels > 32) or
     (BitsPerSample <> ExpectedBits) then
    raise OutputErrorClass.Create('Invalid PCM format');
end;

procedure TAudioOutput.Pause;
begin
  Stop;
end;

procedure TAudioOutput.Flush;
begin
  Stop;
end;

function TAudioOutput.DevicePositionUs: Int64;
var Played, Submitted: Int64;
begin
  Result := -1;
  if (SampleRate > 0) and GetMeterPosition(Played, Submitted) then
    Result := (Played * 1000000) div SampleRate;
end;

function TAudioOutput.QueuedBytes64: Int64;
begin
  Result := GetBufferedBytes;
end;

function TAudioOutput.DeviceLatencyUs: Int64;
begin
  Result := Int64(GetLatencyMS) * 1000;
end;

function TAudioOutput.WaitUntilDrained(TimeoutMS: Cardinal): Boolean;
var Started: UInt64;
begin
  Started := AudioMonotonicMS;
  while GetBufferedBytes > 0 do
  begin
    if Cancelled or ((TimeoutMS > 0) and (AudioMonotonicMS - Started >= TimeoutMS)) then
      Exit(False);
    WaitCancelled(2);
  end;
  Result := True;
end;


function TAudioOutput.GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean;
begin
  PlayedFrame:=0; WriteEndFrame:=0; Result:=False;
end;

function TAudioOutputNull.Open(ARate, AChannels, ABits: Integer): Boolean;
begin
  SampleRate:=ARate;
  Channels:=AChannels;
  BitsPerSample:=ABits;
  ValidateFormat;
  Result:=True;
end;

procedure TAudioOutputNull.Close;
begin
end;

procedure TAudioOutputNull.Start;
begin
end;

procedure TAudioOutputNull.Stop;
begin
end;

function TAudioOutputNull.Write(Buffer: PByte; ByteCount: Integer): Integer;
var
  Delay: Cardinal;
begin
  if (Buffer = nil) or (ByteCount <= 0) or (SampleRate <= 0) or
     (BytesPerFrame <= 0) then Exit(0);
  Delay:=Cardinal((Int64(ByteCount) * 1000) div (SampleRate * BytesPerFrame));
  if WaitCancelled(Delay) then Exit(0);
  Result:=ByteCount;
end;

function TAudioOutputNull.GetBufferedBytes: Integer;
begin
  Result:=0;
end;

function TAudioOutputNull.GetLatencyMS: Integer;
begin
  Result:=0;
end;

constructor TAudioOutput.Create;
begin
  inherited Create;
  FOutputErrorClass := EAudioOutputError;
  FBlockingWrites := True;
  FSampleType := astInt16;
  FVolume := 1.0;
end;

procedure TAudioOutput.SetOutputErrorClass(Value: TAudioOutputErrorClass);
begin
  if Value = nil then FOutputErrorClass := EAudioOutputError
  else FOutputErrorClass := Value;
end;

function TAudioOutput.BytesPerFrame: Integer;
begin
  Result := Channels * (BitsPerSample div 8);
end;

function TAudioOutput.ClampVolume(const Value: Single): Single;
begin
  if Value < 0 then
    Result := 0
  else if Value > 1 then
    Result := 1
  else
    Result := Value;
end;

procedure TAudioOutput.SetMuted(const Value: Boolean);
begin
  FMuted := Value;
end;

procedure TAudioOutput.SetVolume(const Value: Single);
begin
  FVolume := ClampVolume(Value);
end;

end.
