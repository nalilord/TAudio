unit TAudio.Mixer;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$MINFPCONSTPREC 64}{$ENDIF}

{
  Timestamp-driven audio mixer (Float32, interleaved).

  Every input writes at an absolute frame position on the mixer timeline (for
  example graph time * SampleRate, after TAudioClockSync has locked a device
  to the reference clock). Mix(StartFrame, Frames) then renders exactly that
  range into every bus: inputs that are early wait in their buffer, gaps become
  silence, data for an already mixed range is dropped. All three are counted.
  The mixer has no clock of its own; the caller decides when a range is final
  (how long to wait for late inputs).

  Per input: gain (dB or linear, ramped over one Mix block so changes never
  click), mute, balance, and a bus mask (bit n mixes the input into bus n, like
  OBS's tracks). Inputs with fewer channels are spread (mono to every channel),
  inputs with more are truncated to the mixer's channels. A post-fader meter per
  input and a meter per bus (TAudio.Meter) follow every Mix.

  No limiting: a bus can exceed full scale; its meter counts the clipped
  samples. Dynamics (compressor, limiter) belong to the input filter chain.

  Threading: Write is safe from any thread (each input has its own lock);
  parameters may be set from any thread and apply at the next Mix; Mix and the
  bus data belong to one mixing thread. Read meters from the mixing thread or
  through MeterSnapshot.
}

interface

uses
  Classes,
  SyncObjs,
  SysUtils,
  TAudio.Meter;

const
  AUDIO_MIXER_MAX_BUSES = 8;

type
  // Balance laws. All give unity on both channels at the centre (0.5).
  // abConstantPower: sin/cos panning normalised to the centre, so the louder side
  // never exceeds unity; abLinear: the far side fades linearly.
  TAudioBalanceLaw = (abConstantPower, abLinear);

  TAudioMeterSnapshot = record
    PeakDb: array[0..1] of Double;
    RmsDb: array[0..1] of Double;
    Momentary: Double;
    ShortTerm: Double;
    Integrated: Double;
    ClippedSamples: Int64;
  end;

  TAudioMixer = class;

  TAudioMixerInput = class
  private
    FMixer: TAudioMixer;
    FName: string;
    FLock: TCriticalSection;
    // Ring of interleaved samples at the mixer's channel count.
    FRing: TArray<Single>;
    FCapacity: Integer;
    // Absolute frame of the oldest buffered sample and one past the newest.
    FStartFrame, FEndFrame: Int64;
    FHasData: Boolean;
    // Everything before this frame is mixed (the mixer's position for this input).
    FMixedUntil: Int64;
    FMixStarted: Boolean;
    // Parameters (under FLock).
    FGain: Double;
    FMuted: Boolean;
    FBalance: Double;
    FBusMask: Cardinal;
    // Gains last applied, for the ramp.
    FAppliedLeft, FAppliedRight: Double;
    FMeter: TAudioMeter;
    FScratch: TArray<Single>;
    // Counters.
    FFramesWritten: Int64;
    FGapFrames: Int64;
    FLateFrames: Int64;
    FOverflowFrames: Int64;
    FOverlapFrames: Int64;
    FUnderrunFrames: Int64;
    function GetGainDb: Double;
    procedure SetGainDb(AValue: Double);
    procedure SetGain(AValue: Double);
    procedure SetMuted(AValue: Boolean);
    procedure SetBalance(AValue: Double);
    procedure SetBusMask(AValue: Cardinal);
    function GetGain: Double;
    function GetMuted: Boolean;
    function GetBalance: Double;
    function GetBusMask: Cardinal;
    function Slot(AFrame: Int64): Integer;
    procedure Store(ASource: PSingle; ASourceChannels: Integer; AFrame: Int64; AFrames: Integer);
    // Takes [AStart, AStart + AFrames) into FScratch (silence where nothing was written).
    procedure Take(AStart: Int64; AFrames: Integer);
  public
    constructor Create(AMixer: TAudioMixer; const AName: string; ABufferFrames: Integer);
    destructor Destroy; override;
    // Interleaved Float32 with AChannels channels; AStartFrame on the mixer timeline.
    procedure Write(AData: PSingle; AFrames, AChannels: Integer; AStartFrame: Int64);
    // A copy of the post-fader meter, safe from any thread.
    function MeterSnapshot: TAudioMeterSnapshot;
    procedure ResetCounters;
    // One past the newest buffered frame; Low(Int64) before the first write. A caller that mixes
    // without a clock (files, tests) mixes a range once every input has written past it.
    function WrittenUntil: Int64;
    property Name: string read FName;
    property Gain: Double read GetGain write SetGain;
    property GainDb: Double read GetGainDb write SetGainDb;
    property Muted: Boolean read GetMuted write SetMuted;
    // 0 = left only, 0.5 = centre, 1 = right only.
    property Balance: Double read GetBalance write SetBalance;
    property BusMask: Cardinal read GetBusMask write SetBusMask;
    // Post-fader meter; read it on the mixing thread.
    property Meter: TAudioMeter read FMeter;
    property FramesWritten: Int64 read FFramesWritten;
    // Frames missing between writes (filled with silence).
    property GapFrames: Int64 read FGapFrames;
    // Frames written for a range that was already mixed (dropped).
    property LateFrames: Int64 read FLateFrames;
    // Frames written further ahead than the buffer holds (dropped).
    property OverflowFrames: Int64 read FOverflowFrames;
    // Frames written twice for the same range (the later copy is dropped).
    property OverlapFrames: Int64 read FOverlapFrames;
    // Mixed frames for which the input had not delivered anything yet (silence).
    property UnderrunFrames: Int64 read FUnderrunFrames;
  end;

  TAudioMixer = class
  private
    FSampleRate: Integer;
    FChannels: Integer;
    FBusCount: Integer;
    FBufferFrames: Integer;
    FBalanceLaw: TAudioBalanceLaw;
    FInputs: TList;
    FInputsLock: TCriticalSection;
    FBus: array of TArray<Single>;
    FBusMeters: array of TAudioMeter;
    FBusMeterLock: TCriticalSection;
    FBusClipped: array of Int64;
    FPosition: Int64;
    FMixedFrames: Int64;
    function GetBusData(ABus: Integer): PSingle;
    function GetBusMeter(ABus: Integer): TAudioMeter;
    function GetBusClipped(ABus: Integer): Int64;
    function GetInput(AIndex: Integer): TAudioMixerInput;
    function GetInputCount: Integer;
    procedure BalanceGains(ABalance: Double; out ALeft, ARight: Double);
  public
    // ABufferMs: how far ahead of the mix position an input may write.
    constructor Create(ASampleRate: Integer = 48000; AChannels: Integer = 2; ABusCount: Integer = 6;
      ABufferMs: Integer = 1000);
    destructor Destroy; override;
    function AddInput(const AName: string): TAudioMixerInput;
    procedure RemoveInput(AInput: TAudioMixerInput);
    // Renders [AStartFrame, AStartFrame + AFrames) into every bus. Ranges normally follow each
    // other; a range before the previous one is rendered from whatever is still buffered.
    procedure Mix(AStartFrame: Int64; AFrames: Integer);
    function BusMeterSnapshot(ABus: Integer): TAudioMeterSnapshot;
    property BalanceLaw: TAudioBalanceLaw read FBalanceLaw write FBalanceLaw;
    property BusCount: Integer read FBusCount;
    // Interleaved output of the last Mix, AFrames * Channels samples.
    property BusData[ABus: Integer]: PSingle read GetBusData;
    property BusMeter[ABus: Integer]: TAudioMeter read GetBusMeter;
    property BusClippedSamples[ABus: Integer]: Int64 read GetBusClipped;
    property Channels: Integer read FChannels;
    property InputCount: Integer read GetInputCount;
    property Inputs[AIndex: Integer]: TAudioMixerInput read GetInput;
    property MixedFrames: Int64 read FMixedFrames;
    // One past the last mixed frame.
    property Position: Int64 read FPosition;
    property SampleRate: Integer read FSampleRate;
  end;

implementation

uses
  Math;

function Snapshot(AMeter: TAudioMeter): TAudioMeterSnapshot;
var
  C: Integer;
begin
  Result:=Default(TAudioMeterSnapshot);
  for C:=0 to Min(AMeter.Channels, 2) - 1 do
  begin
    Result.PeakDb[C]:=AMeter.PeakDb[C];
    Result.RmsDb[C]:=AMeter.RmsDb[C];
  end;
  Result.Momentary:=AMeter.Momentary;
  Result.ShortTerm:=AMeter.ShortTerm;
  Result.Integrated:=AMeter.Integrated;
  Result.ClippedSamples:=AMeter.ClippedSamples;
end;

{ TAudioMixerInput }

constructor TAudioMixerInput.Create(AMixer: TAudioMixer; const AName: string; ABufferFrames: Integer);
begin
  inherited Create;
  FMixer:=AMixer;
  FName:=AName;
  FLock:=TCriticalSection.Create;
  FCapacity:=ABufferFrames;
  SetLength(FRing, FCapacity * AMixer.Channels);
  FGain:=1;
  FBalance:=0.5;
  FBusMask:=1;
  FAppliedLeft:=-1;
  FAppliedRight:=-1;
  FMeter:=TAudioMeter.Create(AMixer.SampleRate, AMixer.Channels);
end;

destructor TAudioMixerInput.Destroy;
begin
  FMeter.Free;
  FLock.Free;
  inherited Destroy;
end;

function TAudioMixerInput.GetGain: Double;
begin
  FLock.Acquire;
  try
    Result:=FGain;
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.SetGain(AValue: Double);
begin
  if AValue < 0 then
    AValue:=0;
  FLock.Acquire;
  try
    FGain:=AValue;
  finally
    FLock.Release;
  end;
end;

function TAudioMixerInput.GetGainDb: Double;
begin
  Result:=AudioLinearToDb(GetGain);
end;

procedure TAudioMixerInput.SetGainDb(AValue: Double);
begin
  SetGain(AudioDbToLinear(AValue));
end;

function TAudioMixerInput.GetMuted: Boolean;
begin
  FLock.Acquire;
  try
    Result:=FMuted;
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.SetMuted(AValue: Boolean);
begin
  FLock.Acquire;
  try
    FMuted:=AValue;
  finally
    FLock.Release;
  end;
end;

function TAudioMixerInput.GetBalance: Double;
begin
  FLock.Acquire;
  try
    Result:=FBalance;
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.SetBalance(AValue: Double);
begin
  FLock.Acquire;
  try
    FBalance:=EnsureRange(AValue, 0, 1);
  finally
    FLock.Release;
  end;
end;

function TAudioMixerInput.GetBusMask: Cardinal;
begin
  FLock.Acquire;
  try
    Result:=FBusMask;
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.SetBusMask(AValue: Cardinal);
begin
  FLock.Acquire;
  try
    FBusMask:=AValue;
  finally
    FLock.Release;
  end;
end;

// Ring index of an absolute frame (also for frames before zero).
function TAudioMixerInput.Slot(AFrame: Int64): Integer;
begin
  Result:=Integer(AFrame MOD FCapacity);
  if Result < 0 then
    Inc(Result, FCapacity);
end;

// Copies AFrames source frames into the ring at absolute AFrame (caller holds FLock and has
// checked that the range fits).
procedure TAudioMixerInput.Store(ASource: PSingle; ASourceChannels: Integer; AFrame: Int64; AFrames: Integer);
var
  F, C, Ch, Base: Integer;
  Src: PSingle;
begin
  Ch:=FMixer.Channels;
  for F:=0 to AFrames - 1 do
  begin
    Base:=Slot(AFrame + F) * Ch;
    Src:=ASource;
    Inc(Src, F * ASourceChannels);
    for C:=0 to Ch - 1 do
      if ASourceChannels = 1 then
        FRing[Base + C]:=Src^
      else if C < ASourceChannels then
        FRing[Base + C]:=PSingle(PByte(Src) + C * SizeOf(Single))^
      else
        FRing[Base + C]:=0;
  end;
end;

procedure TAudioMixerInput.Write(AData: PSingle; AFrames, AChannels: Integer; AStartFrame: Int64);
var
  Skip, Fill, I, Ch: Integer;
  Limit: Int64;
  Src: PSingle;
begin
  if (AFrames <= 0) OR (AChannels <= 0) OR (AData = nil) then
    Exit;
  Ch:=FMixer.Channels;
  FLock.Acquire;
  try
    Inc(FFramesWritten, AFrames);
    Src:=AData;
    // Part of the range that is already mixed: too late.
    if FMixStarted AND (AStartFrame < FMixedUntil) then
    begin
      Skip:=Integer(Min(Int64(AFrames), FMixedUntil - AStartFrame));
      Inc(FLateFrames, Skip);
      Inc(Src, Skip * AChannels);
      Inc(AStartFrame, Skip);
      Dec(AFrames, Skip);
    end;
    if AFrames <= 0 then
      Exit;
    if NOT FHasData then
    begin
      FStartFrame:=AStartFrame;
      FEndFrame:=AStartFrame;
      if FMixStarted AND (AStartFrame > FMixedUntil) then
      begin
        FStartFrame:=FMixedUntil;
        FEndFrame:=FMixedUntil;
      end;
      FHasData:=True;
    end;
    // Already buffered: keep the first copy.
    if AStartFrame < FEndFrame then
    begin
      Skip:=Integer(Min(Int64(AFrames), FEndFrame - AStartFrame));
      Inc(FOverlapFrames, Skip);
      Inc(Src, Skip * AChannels);
      Inc(AStartFrame, Skip);
      Dec(AFrames, Skip);
      if AFrames <= 0 then
        Exit;
    end;
    // Only FCapacity frames fit after the oldest buffered one.
    Limit:=FStartFrame + FCapacity;
    if AStartFrame + AFrames > Limit then
    begin
      Skip:=Integer(Min(Int64(AFrames), AStartFrame + AFrames - Limit));
      Inc(FOverflowFrames, Skip);
      Dec(AFrames, Skip);
      if AFrames <= 0 then
        Exit;
    end;
    // A gap since the last write becomes silence.
    if AStartFrame > FEndFrame then
    begin
      Fill:=Integer(AStartFrame - FEndFrame);
      Inc(FGapFrames, Fill);
      for I:=0 to Fill - 1 do
        FillChar(FRing[Slot(FEndFrame + I) * Ch], Ch * SizeOf(Single), 0);
    end;
    Store(Src, AChannels, AStartFrame, AFrames);
    FEndFrame:=AStartFrame + AFrames;
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.Take(AStart: Int64; AFrames: Integer);
var
  Ch, F: Integer;
  Frame: Int64;
begin
  Ch:=FMixer.Channels;
  if Length(FScratch) < AFrames * Ch then
    SetLength(FScratch, AFrames * Ch);
  for F:=0 to AFrames - 1 do
  begin
    Frame:=AStart + F;
    if FHasData AND (Frame >= FStartFrame) AND (Frame < FEndFrame) then
      Move(FRing[Slot(Frame) * Ch], FScratch[F * Ch], Ch * SizeOf(Single))
    else
    begin
      FillChar(FScratch[F * Ch], Ch * SizeOf(Single), 0);
      Inc(FUnderrunFrames);
    end;
  end;
  // Release what is mixed.
  FMixedUntil:=Max(FMixedUntil, AStart + AFrames);
  if NOT FMixStarted then
  begin
    FMixedUntil:=AStart + AFrames;
    FMixStarted:=True;
  end;
  if FHasData then
  begin
    if FMixedUntil >= FEndFrame then
      FHasData:=False
    else if FMixedUntil > FStartFrame then
      FStartFrame:=FMixedUntil;
  end;
end;

function TAudioMixerInput.MeterSnapshot: TAudioMeterSnapshot;
begin
  FLock.Acquire;
  try
    Result:=Snapshot(FMeter);
  finally
    FLock.Release;
  end;
end;

function TAudioMixerInput.WrittenUntil: Int64;
begin
  FLock.Acquire;
  try
    if FHasData then
      Result:=FEndFrame
    else if FMixStarted AND (FFramesWritten > 0) then
      Result:=FMixedUntil
    else if FFramesWritten > 0 then
      Result:=FEndFrame
    else
      Result:=Low(Int64);
  finally
    FLock.Release;
  end;
end;

procedure TAudioMixerInput.ResetCounters;
begin
  FLock.Acquire;
  try
    FFramesWritten:=0;
    FGapFrames:=0;
    FLateFrames:=0;
    FOverflowFrames:=0;
    FOverlapFrames:=0;
    FUnderrunFrames:=0;
  finally
    FLock.Release;
  end;
end;

{ TAudioMixer }

constructor TAudioMixer.Create(ASampleRate, AChannels, ABusCount, ABufferMs: Integer);
var
  B: Integer;
begin
  inherited Create;
  if (ASampleRate <= 0) OR (AChannels <= 0) OR (ABusCount < 1) OR (ABusCount > AUDIO_MIXER_MAX_BUSES) then
    raise EArgumentException.Create('TAudioMixer: invalid sample rate, channel or bus count');
  FSampleRate:=ASampleRate;
  FChannels:=AChannels;
  FBusCount:=ABusCount;
  FBufferFrames:=Max(1, Int64(ASampleRate) * ABufferMs DIV 1000);
  FInputs:=TList.Create;
  FInputsLock:=TCriticalSection.Create;
  FBusMeterLock:=TCriticalSection.Create;
  SetLength(FBus, ABusCount);
  SetLength(FBusMeters, ABusCount);
  SetLength(FBusClipped, ABusCount);
  for B:=0 to ABusCount - 1 do
    FBusMeters[B]:=TAudioMeter.Create(ASampleRate, AChannels);
end;

destructor TAudioMixer.Destroy;
var
  I: Integer;
begin
  for I:=0 to FInputs.Count - 1 do
    TObject(FInputs[I]).Free;
  FInputs.Free;
  for I:=0 to High(FBusMeters) do
    FBusMeters[I].Free;
  FInputsLock.Free;
  FBusMeterLock.Free;
  inherited Destroy;
end;

function TAudioMixer.AddInput(const AName: string): TAudioMixerInput;
begin
  Result:=TAudioMixerInput.Create(Self, AName, FBufferFrames);
  FInputsLock.Acquire;
  try
    FInputs.Add(Result);
  finally
    FInputsLock.Release;
  end;
end;

procedure TAudioMixer.RemoveInput(AInput: TAudioMixerInput);
begin
  FInputsLock.Acquire;
  try
    if FInputs.IndexOf(AInput) >= 0 then
    begin
      FInputs.Delete(FInputs.IndexOf(AInput));
      AInput.Free;
    end;
  finally
    FInputsLock.Release;
  end;
end;

procedure TAudioMixer.BalanceGains(ABalance: Double; out ALeft, ARight: Double);
begin
  if Abs(ABalance - 0.5) < 1E-9 then
  begin
    ALeft:=1;
    ARight:=1;
    Exit;
  end;
  case FBalanceLaw of
    abLinear:
      begin
        ALeft:=Min(1, 2 * (1 - ABalance));
        ARight:=Min(1, 2 * ABalance);
      end;
  else
    begin
      ALeft:=Min(1, Sqrt(2) * Cos(ABalance * Pi / 2));
      ARight:=Min(1, Sqrt(2) * Sin(ABalance * Pi / 2));
    end;
  end;
end;

procedure TAudioMixer.Mix(AStartFrame: Int64; AFrames: Integer);
var
  I, B, F, C: Integer;
  Input: TAudioMixerInput;
  Gain, Balance, Left, Right, L0, R0, GL, GR, T: Double;
  Mask: Cardinal;
  Muted: Boolean;
  P: PSingle;
  X: Single;
begin
  if AFrames <= 0 then
    Exit;
  for B:=0 to FBusCount - 1 do
  begin
    if Length(FBus[B]) < AFrames * FChannels then
      SetLength(FBus[B], AFrames * FChannels);
    FillChar(FBus[B][0], AFrames * FChannels * SizeOf(Single), 0);
  end;

  FInputsLock.Acquire;
  try
    for I:=0 to FInputs.Count - 1 do
    begin
      Input:=TAudioMixerInput(FInputs[I]);
      Input.FLock.Acquire;
      try
        Input.Take(AStartFrame, AFrames);
        Gain:=Input.FGain;
        Muted:=Input.FMuted;
        Balance:=Input.FBalance;
        Mask:=Input.FBusMask;
        if Muted then
          Gain:=0;
        BalanceGains(Balance, Left, Right);
        Left:=Left * Gain;
        Right:=Right * Gain;
        // Ramp from the gains applied last block, so a change never clicks.
        L0:=Input.FAppliedLeft;
        R0:=Input.FAppliedRight;
        if L0 < 0 then
        begin
          L0:=Left;
          R0:=Right;
        end;
        Input.FAppliedLeft:=Left;
        Input.FAppliedRight:=Right;
        P:=@Input.FScratch[0];
        for F:=0 to AFrames - 1 do
        begin
          T:=(F + 1) / AFrames;
          GL:=L0 + (Left - L0) * T;
          GR:=R0 + (Right - R0) * T;
          for C:=0 to FChannels - 1 do
          begin
            // Balance acts on a stereo pair; other channels follow the plain gain.
            if FChannels = 2 then
            begin
              if C = 0 then
                P^:=P^ * GL
              else
                P^:=P^ * GR;
            end else
              P^:=P^ * (GL + GR) / 2;
            Inc(P);
          end;
        end;
        Input.FMeter.Process(@Input.FScratch[0], AFrames);
        for B:=0 to FBusCount - 1 do
          if (Mask AND (Cardinal(1) SHL B)) <> 0 then
            for F:=0 to AFrames * FChannels - 1 do
              FBus[B][F]:=FBus[B][F] + Input.FScratch[F];
      finally
        Input.FLock.Release;
      end;
    end;
  finally
    FInputsLock.Release;
  end;

  FBusMeterLock.Acquire;
  try
    for B:=0 to FBusCount - 1 do
    begin
      for F:=0 to AFrames * FChannels - 1 do
      begin
        X:=FBus[B][F];
        if Abs(X) >= 1 then
          Inc(FBusClipped[B]);
      end;
      FBusMeters[B].Process(@FBus[B][0], AFrames);
    end;
  finally
    FBusMeterLock.Release;
  end;
  FPosition:=AStartFrame + AFrames;
  Inc(FMixedFrames, AFrames);
end;

function TAudioMixer.BusMeterSnapshot(ABus: Integer): TAudioMeterSnapshot;
begin
  FBusMeterLock.Acquire;
  try
    Result:=Snapshot(FBusMeters[ABus]);
  finally
    FBusMeterLock.Release;
  end;
end;

function TAudioMixer.GetBusClipped(ABus: Integer): Int64;
begin
  Result:=FBusClipped[ABus];
end;

function TAudioMixer.GetBusData(ABus: Integer): PSingle;
begin
  if Length(FBus[ABus]) = 0 then
    Result:=nil
  else
    Result:=@FBus[ABus][0];
end;

function TAudioMixer.GetBusMeter(ABus: Integer): TAudioMeter;
begin
  Result:=FBusMeters[ABus];
end;

function TAudioMixer.GetInput(AIndex: Integer): TAudioMixerInput;
begin
  FInputsLock.Acquire;
  try
    Result:=TAudioMixerInput(FInputs[AIndex]);
  finally
    FInputsLock.Release;
  end;
end;

function TAudioMixer.GetInputCount: Integer;
begin
  FInputsLock.Acquire;
  try
    Result:=FInputs.Count;
  finally
    FInputsLock.Release;
  end;
end;

end.
