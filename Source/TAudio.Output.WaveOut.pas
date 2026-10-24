unit TAudio.Output.WaveOut;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$POINTERMATH ON}

interface

uses
{$IFDEF FPC}
  Windows, MMSystem, Classes, SysUtils,
{$ELSE}
  Winapi.Windows, Winapi.MMSystem, System.Classes, System.SysUtils,
{$ENDIF}
  TAudio.Output;

type
  TAudioOutputWaveOut = class(TAudioOutput)
  private
    FHandle: HWAVEOUT;
    FPending: TList;
    FPaused: Boolean;
    FDeviceId: Cardinal;
    FApplyVolumeOnOpen: Boolean;
    FWrittenFrames: Int64;
    FPositionWrap: Int64;
    FLastPosition: Cardinal;
    procedure Check(Code: MMRESULT; const Action: string);
    procedure CleanupCompleted;
    procedure ClearPending;
    procedure ApplyVolume;
  public
    constructor Create; override;
    destructor Destroy; override;
    function Open(SampleRate, Channels, BitsPerSample: Integer): Boolean; override;
    function OpenPCM(ARate, AChannels: Integer; AType: TAudioSampleType): Boolean;
    procedure Close; override;
    procedure Start; override;
    procedure Pause; override;
    procedure Stop; override;
    procedure Flush; override;
    function Write(Buffer: PByte; ByteCount: Integer): Integer; override;
    function GetBufferedBytes: Integer; override;
    function QueuedBytes64: Int64; override;
    function GetLatencyMS: Integer; override;
    function DeviceLatencyUs: Int64; override;
    function GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean; override;
    procedure SetVolume(const Value: Single); override;
    procedure SetMuted(const Value: Boolean); override;
    property DeviceId: Cardinal read FDeviceId write FDeviceId;
    property ApplyVolumeOnOpen: Boolean read FApplyVolumeOnOpen write FApplyVolumeOnOpen;
  end;

implementation

const
  WAVE_FORMAT_IEEE_FLOAT = 3;

type
  TWaveBuffer = class
    Header: TWaveHdr;
    Data: TBytes;
    Prepared: Boolean;
  end;

constructor TAudioOutputWaveOut.Create;
begin
  inherited;
  FPending:=TList.Create;
  FDeviceId:=Cardinal(WAVE_MAPPER);
  FApplyVolumeOnOpen:=True;
end;

destructor TAudioOutputWaveOut.Destroy;
begin
  Close;
  FPending.Free;
  inherited;
end;

procedure TAudioOutputWaveOut.Check(Code: MMRESULT; const Action: string);
begin
  if Code <> MMSYSERR_NOERROR then
    raise OutputErrorClass.CreateFmt('%s failed (%d)', [Action, Code]);
end;

procedure TAudioOutputWaveOut.CleanupCompleted;
var
  I: Integer;
  Item: TWaveBuffer;
begin
  for I:=FPending.Count - 1 downto 0 do
  begin
    Item:=TWaveBuffer(FPending[I]);
    if (Item.Header.dwFlags AND WHDR_DONE) <> 0 then
    begin
      Check(waveOutUnprepareHeader(FHandle, @Item.Header, SizeOf(Item.Header)), 'waveOutUnprepareHeader');
      FPending.Delete(I);
      Item.Free;
    end;
  end;
end;

procedure TAudioOutputWaveOut.ClearPending;
var
  Item: TWaveBuffer;
begin
  while FPending.Count > 0 do
  begin
    Item:=TWaveBuffer(FPending[FPending.Count - 1]);
    if Item.Prepared then
      Check(waveOutUnprepareHeader(FHandle, @Item.Header, SizeOf(Item.Header)), 'waveOutUnprepareHeader');
    FPending.Delete(FPending.Count - 1);
    Item.Free;
  end;
end;

procedure TAudioOutputWaveOut.Close;
begin
  if FHandle = 0 then
    Exit;
  Check(waveOutReset(FHandle), 'waveOutReset');
  ClearPending;
  Check(waveOutClose(FHandle), 'waveOutClose');
  FHandle:=0;
  FPaused:=False;
end;

function TAudioOutputWaveOut.OpenPCM(ARate, AChannels: Integer; AType: TAudioSampleType): Boolean;
var
  Bits: Integer;
begin
  SampleType:=AType;
  case AType of
    astUInt8: Bits:=8;
    astInt16: Bits:=16;
    else Bits:=32;
  end;
  Result:=Open(ARate, AChannels, Bits);
end;

function TAudioOutputWaveOut.Open(SampleRate, Channels, BitsPerSample: Integer): Boolean;
var
  Format: TWaveFormatEx;
begin
  Close;
  Self.SampleRate:=SampleRate;
  Self.Channels:=Channels;
  Self.BitsPerSample:=BitsPerSample;
  if SampleType <> astFloat32 then
    case BitsPerSample of
      8: SampleType:=astUInt8;
      16: SampleType:=astInt16;
      32: SampleType:=astInt32;
    end;
  ValidateFormat;
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag:=WAVE_FORMAT_PCM;
  if SampleType = astFloat32 then
    Format.wFormatTag:=WAVE_FORMAT_IEEE_FLOAT;
  Format.nChannels:=Channels;
  Format.nSamplesPerSec:=SampleRate;
  Format.wBitsPerSample:=BitsPerSample;
  Format.nBlockAlign:=BytesPerFrame;
  Format.nAvgBytesPerSec:=SampleRate * BytesPerFrame;
  Check(waveOutOpen(@FHandle, FDeviceId, @Format, 0, 0, CALLBACK_NULL), 'waveOutOpen');
  FWrittenFrames:=0;
  FPositionWrap:=0;
  FLastPosition:=0;
  if FApplyVolumeOnOpen then
    ApplyVolume;
  Result:=True;
end;

procedure TAudioOutputWaveOut.Start;
begin
  if FHandle <> 0 then
    Check(waveOutRestart(FHandle), 'waveOutRestart');
  FPaused:=False;
end;

procedure TAudioOutputWaveOut.Pause;
begin
  if FHandle <> 0 then
    Check(waveOutPause(FHandle), 'waveOutPause');
  FPaused:=True;
end;

procedure TAudioOutputWaveOut.Flush;
begin
  if FHandle = 0 then
    Exit;
  Check(waveOutReset(FHandle), 'waveOutReset');
  ClearPending;
  FWrittenFrames:=0;
  FPositionWrap:=0;
  FLastPosition:=0;
  if FPaused then
    Pause
  else
    Start;
end;

procedure TAudioOutputWaveOut.Stop;
begin
  Flush;
end;

function TAudioOutputWaveOut.Write(Buffer: PByte; ByteCount: Integer): Integer;
var
  Item: TWaveBuffer;
  Chunk, Remaining: Integer;
begin
  Result:=0;
  if (FHandle = 0) OR (Buffer = nil) OR (ByteCount <= 0) then
    Exit;
  Remaining:=ByteCount - ByteCount MOD BytesPerFrame;
  while Remaining > 0 do
  begin
    if Cancelled then
      Exit;
    CleanupCompleted;
    // Blocking writes use a bounded queue. Asynchronous callers are
    // responsible for limiting the number of pending buffers.
    if BlockingWrites AND (GetBufferedBytes >= 12 * 8192) then
    begin
      if WaitCancelled(2) then
        Exit;
      Continue;
    end;
    Chunk:=Remaining;
    if BlockingWrites AND (Chunk > 8192) then
      Chunk:=8192;
    Chunk:=Chunk - Chunk MOD BytesPerFrame;
    Item:=TWaveBuffer.Create;
    try
      SetLength(Item.Data, Chunk);
      Move(Buffer[Result], Item.Data[0], Chunk);
      Item.Header.lpData:=PAnsiChar(@Item.Data[0]);
      Item.Header.dwBufferLength:=Chunk;
      Check(waveOutPrepareHeader(FHandle, @Item.Header, SizeOf(Item.Header)), 'waveOutPrepareHeader');
      Item.Prepared:=True;
      // Reserve list ownership before submitting memory to the driver.
      FPending.Add(Item);
      try
        Check(waveOutWrite(FHandle, @Item.Header, SizeOf(Item.Header)), 'waveOutWrite');
      except
        FPending.Remove(Item);
        raise;
      end;
      Item:=nil;
    finally
      if Item <> nil then
      begin
        if Item.Prepared then
          waveOutUnprepareHeader(FHandle, @Item.Header, SizeOf(Item.Header));
        Item.Free;
      end;
    end;
    Inc(Result, Chunk);
    Dec(Remaining, Chunk);
    Inc(FWrittenFrames, Chunk DIV BytesPerFrame);
  end;
end;

function TAudioOutputWaveOut.GetBufferedBytes: Integer;
var
  Total: Int64;
begin
  Total:=QueuedBytes64;
  if Total > High(Integer) then
    Result:=High(Integer)
  else
    Result:=Total;
end;

function TAudioOutputWaveOut.QueuedBytes64: Int64;
var
  I: Integer;
begin
  CleanupCompleted;
  Result:=0;
  for I:=0 to FPending.Count - 1 do
    Inc(Result, TWaveBuffer(FPending[I]).Header.dwBufferLength);
end;

function TAudioOutputWaveOut.GetLatencyMS: Integer;
begin
  Result:=0;
  if (SampleRate > 0) AND (BytesPerFrame > 0) then
    Result:=(Int64(GetBufferedBytes) * 1000) DIV (Int64(SampleRate) * BytesPerFrame);
end;

function TAudioOutputWaveOut.DeviceLatencyUs: Int64;
begin
  Result:=-1; // WaveOut does not report a device stream latency.
end;

function TAudioOutputWaveOut.GetMeterPosition(out PlayedFrame, WriteEndFrame: Int64): Boolean;
var
  Position: TMMTime;
begin
  PlayedFrame:=0;
  WriteEndFrame:=FWrittenFrames;
  FillChar(Position, SizeOf(Position), 0);
  Position.wType:=TIME_SAMPLES;
  Result:=(FHandle <> 0) AND (waveOutGetPosition(FHandle, @Position, SizeOf(Position)) = MMSYSERR_NOERROR) AND (Position.wType = TIME_SAMPLES);
  if NOT Result then
    Exit;
  if Position.sample < FLastPosition then
    Inc(FPositionWrap, Int64(1) SHL 32);
  FLastPosition:=Position.sample;
  PlayedFrame:=FPositionWrap + Position.sample;
end;

procedure TAudioOutputWaveOut.ApplyVolume;
var
  Level: Cardinal;
begin
  if FHandle = 0 then
    Exit;
  if Muted then
    Level:=0
  else
    Level:=Round(Volume * $FFFF);
  waveOutSetVolume(FHandle, Level OR (Level SHL 16));
end;

procedure TAudioOutputWaveOut.SetVolume(const Value: Single);
begin
  inherited;
  ApplyVolume;
end;

procedure TAudioOutputWaveOut.SetMuted(const Value: Boolean);
begin
  inherited;
  ApplyVolume;
end;

end.
