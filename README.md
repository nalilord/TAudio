# TAudio

Reusable PCM audio output for Delphi applications. TAudio provides WaveOut and
WASAPI backends with device selection, hardware timing, volume control, buffering
and cancellation. The base types are platform neutral; the native backends use
Windows system APIs and require no additional runtime DLLs.

Add `Source` to your unit search path and rebuild all dependent units. This is a
source library; it does not require a component package or a particular UI toolkit.

## Units

| Unit | Purpose |
| --- | --- |
| `TAudio.Types` | PCM sample types, volume modes and device information |
| `TAudio.Output` | Output contract, cancellation, timing, drain and paced null output |
| `TAudio.Output.WaveOut` | Default/explicit device selection, PCM U8/S16/S32/F32, owned buffers and hardware position |
| `TAudio.Output.WASAPI` | Shared-mode rendering, device enumeration, mix/explicit PCM formats, volume and hardware clocks |
| `TAudio.Windows` | Minimal native COM declarations and device-property access |
| `TAudio.Clock` | High-resolution monotonic microseconds (QPC on Windows), the WASAPI timestamp timebase |
| `TAudio.Input` | Capture contract: packets with device position and capture time, delivered on a capture thread |
| `TAudio.Input.WASAPI` | Shared-mode capture of capture endpoints and loopback of render endpoints, QPC timestamps |
| `TAudio.Resample` | Variable-ratio Float32 resampler (Kaiser-windowed sinc, 32 taps, 1024 phases) |
| `TAudio.ClockSync` | Locks a capture device clock to the reference clock: drift fit, bounded-ratio resampling, counted resyncs |
| `TAudio.Mixer` | Timestamp-driven mixer: inputs written at absolute frames, gain/mute/balance, bus masks (tracks), counted gaps and late data |
| `TAudio.Meter` | Peak, RMS and EBU R128 loudness (momentary, short-term, gated integrated) on BS.1770 K-weighting |
| `TAudio.Dynamics` | Gain, compressor (soft knee, sidechain) and look-ahead true-peak limiter; filters for mixer inputs or standalone |

## Capturing and clock drift

```pascal
uses TAudio.Input, TAudio.Input.WASAPI, TAudio.ClockSync;

// Input:=TAudioInputWASAPI.Create;   DeviceId:='' = default capture endpoint,
// Input.Loopback:=True captures what a render endpoint plays.
// Input.OnData:=HandleData;          called on the capture thread
// Input.Open; Input.Start;
//
// procedure TForm1.HandleData(Sender: TObject; const Packet: TAudioInputPacket);
//   convert Packet.Data to Float32, then
//   Sync.Push(Floats, Packet.Frames, Packet.CaptureTimeUs, Output, 0, NOT Packet.TimestampError);
```

Every device crystal runs slightly off its nominal rate (this test rig: a Realtek
codec at -0.8 ppm, a Sound BlasterX AE-5 at -23.6 ppm, AMD HDMI audio at +5.2 ppm
against QPC). `TAudioClockSync` measures that against the packets' QPC capture
times and resamples so output frame k belongs to reference time
`OriginUs + k / NominalRate`. Corrections stay within `MaxCorrectionPpm`; only
stalls and glitches beyond `ResyncThresholdMs` drop or insert samples, and they
are counted. `Examples/CaptureDrift` measures any set of endpoints at once;
`Tests/AudioClockSyncSmoke` checks the controller against a simulated device
(steady and wandering drift up to 8 h, stalls, timestamp glitches, tone quality).
`Tests/AudioClockLoopTest` is the long-run hardware check: device A plays a click
every second, a cable feeds it into device B, and the clock-synced arrival times
in A's loopback and B's capture must keep a constant offset (the analog delay)
while the uncorrected offset drifts by the devices' ppm difference.

## Mixing

```pascal
uses TAudio.Mixer;

// Mixer:=TAudioMixer.Create(48000, 2, 6);    // stereo, six buses (tracks)
// Mic:=Mixer.AddInput('Microphone');
// Mic.GainDb:=-3; Mic.BusMask:=%11;         // tracks 1 and 2
// Browser.Active:=False;                    // automation gate (e.g. picture off air), next to Muted
// Browser.ActiveGain:=0.25;                // the gate as a level, for crossfades
// capture thread: Mic.Write(Floats, Frames, Channels, StartFrame);
// mixing thread:  Mixer.Mix(Position, 480); then read Mixer.BusData[0]
```

Inputs write at absolute positions on the mixer timeline, so live devices locked
to the reference clock by `TAudioClockSync` line up sample-exactly however they
chunk their packets. `Mix(StartFrame, Frames)` renders exactly that range; data
that is early waits, gaps are silence, data for an already mixed range is
dropped, and all of it is counted per input. The mixer has no clock: the caller
decides when a range is final. Gain changes ramp over one block. Every input has
a post-fader meter and every bus a meter (`TAudio.Meter`, EBU R128 loudness, sample
peak, RMS, clip count). `Tests/AudioMixerSmoke` checks both, including the BS.1770
filter coefficients and the EBU Tech 3341 reference levels.

### Dynamics

```pascal
uses TAudio.Dynamics, TAudio.Mixer;

// Ducker:=TAudioCompressor.Create('ducker');
// Ducker.ThresholdDb:=-30; Ducker.Ratio:=10; Ducker.AttackMs:=5; Ducker.ReleaseMs:=300;
// Music.AddFilter(Ducker, Mic);           // the mic's signal drives the music's compressor
// Music.AddFilter(TAudioLimiter.Create);  // -1 dBTP, 1.5 ms look-ahead
```

Each input runs its filter chain before the fader. A filter can take another
input as its sidechain: it sees that input's filtered signal before the fader,
silent while it is muted, and inputs feeding a sidechain are processed first;
cycles are rejected. The limiter adds latency (77 frames at 48 kHz by default);
the mixer reads that input ahead by its chain latency, so every input stays
sample-aligned, and `TAudioMixer.Latency` tells the caller how much more data a
range needs. Compressor: one-pole attack/release on the peak level, static curve
in dB with an optional soft knee. Limiter: 4x true-peak detector, sliding
minimum plus moving average over the look-ahead window, so no sample exceeds the
ceiling and the gain never steps. `Tests/AudioDynamicsSmoke` (20 checks) measures
the static curves, timing, ceilings against a 16x reference interpolator, and the
mixer's alignment and ducking. Cost at 48 kHz stereo (FPC -O2, one core): limiter
86x real time, compressor 577x.

## Opening and writing

```pascal
uses TAudio.Output, TAudio.Output.WASAPI;

var
  Output: TAudioOutputWASAPI;
begin
  Output:=TAudioOutputWASAPI.Create;
  try
    Output.Open(48000, 2, 16);
    // Open negotiates the device mix format. Configure your PCM producer using
    // Output.SampleRate, Channels, BitsPerSample and SampleType before writing.
    Output.Start;
    // Accepted:=Output.Write(PCM, ByteCount);
    // Handle partial writes without resubmitting bytes already accepted.
    Output.WaitUntilDrained(2000);
  finally
    Output.Free;
  end;
end;
```

Use `OpenPCM(rate, channels, sampleType)` for an explicit input format. WASAPI
accepts `astInt16` and `astFloat32` without silently converting input data. WaveOut
also accepts `astUInt8` and `astInt32`. Supply complete interleaved sample frames.
`Write` returns bytes accepted; callers retain ownership of the input and can
release accepted data after the call returns.

`BlockingWrites` defaults to true. Assign a borrowed `StopEvent: TEvent` to
interrupt blocked writes/drains. Keep it alive until the output is closed and
workers have stopped.

With `BlockingWrites = False`, WASAPI returns when its device buffer is full.
WaveOut instead queues owned buffers asynchronously; the caller must bound the
queue. The default blocking WaveOut path bounds pending data to approximately
twelve 8 KiB buffers. `QueuedBytes64` provides full queue accounting; the integer
`GetBufferedBytes` interface saturates at `High(Integer)`.

## Lifecycle and timing

- `Pause` retains queued PCM; `Start` resumes it.
- `Stop` discards queued PCM and resets the device-position epoch.
- `Flush` discards/reset while retaining the running/paused state.
- `WaitUntilDrained(ms)` returns false on cancellation or timeout. Zero means no
  timeout; a paused queue cannot drain until resumed or discarded.
- `GetMeterPosition` returns played and write-end positions in output sample
  frames on a common timeline. WASAPI re-anchors after underruns and freezes the
  last meter position on a transient clock-query failure.
- `DevicePositionUs` exposes the raw device clock separately from meter timing.
- `DeviceLatencyUs` reports WASAPI stream latency. WaveOut returns -1 because it
  cannot report this value. Its `GetLatencyMS` reports estimated queued duration.
- `Close` releases buffers/interfaces and can be called repeatedly.

Outputs are not generally thread-safe. Serialize control calls and writes; only
cancellation-event signaling is intended to occur concurrently. Open/close and
destroy WASAPI on the same thread so COM initialization remains balanced. Device
enumeration initializes/releases COM independently. There is no hidden render
thread. Application scheduling and media-timestamp mapping remain with the caller.

## Devices, volume and errors

WASAPI defaults to the multimedia render endpoint. Set `DeviceId` before opening
to select an explicit endpoint. `EnumerateDevices` returns identifiers,
friendly/interface/description names, state flags/text and default-device status,
including inactive endpoints. See [ListDevices.dpr](Examples/ListDevices.dpr).

`VolumeMode` defaults to `avmSession`. Endpoint-wide changes require explicit
`avmEndpoint`; unavailable session control never falls back to endpoint volume.
`ApplyVolumeOnOpen` defaults to true. Set it false to leave existing volume alone
when opening. Explicit `SetVolume`/`SetMuted` calls still apply their controls.

Failures use `EAudioOutputError`. Integrations needing a specific exception type
can assign a subclass through `OutputErrorClass`; native failures then use that
class. Setting the property to nil restores the default exception type.

## Build and test

From WSL with a licensed Delphi installation:

```bash
./build.sh Examples/ListDevices.dpr Win64
./Bin/win64/ListDevices.exe
./build.sh Tests/AudioOutputSmoke.dpr Win64
./Bin/win64/AudioOutputSmoke.exe
./build.sh Tests/AudioOutputSmoke.dpr Win32
./Bin/win32/AudioOutputSmoke.exe
```

`BDS_DIR` selects the RAD Studio installation using a WSL path. Otherwise,
`BDS_VERSION` selects a version under the standard Windows installation directory
(default `23.0`). `DCC32`, `DCC64`, `DELPHI_LIB_WIN32` and `DELPHI_LIB_WIN64` can
override individual compiler/library paths. Outputs go to ignored `Bin/` folders.
IDE builds only need `Source` on the unit search path.

The smoke test requires an available Windows audio device. It writes silence,
avoids endpoint-volume changes and checks:

- All four WaveOut PCM types and WASAPI mix/explicit format modes.
- Native record sizes, device enumeration/properties and explicit selection.
- Hardware clocks, paused queues, drain, flush and cancellation.
- Failed-open cleanup/recovery and custom exception types.

The output backends have been exercised with Delphi Win32 and Win64. The base
units also compile with FPC on Linux; native Windows/FPC execution, mobile audio
and every possible device/driver combination are not qualified by these tests.
WASAPI currently uses shared mode and polling, without an event-driven render loop
or automatic device-switch recovery.

## Licensing

See [LICENSE](LICENSE) for the BSD 2-Clause license. Native audio services are
provided by Windows; their binaries are not distributed in this repository.
