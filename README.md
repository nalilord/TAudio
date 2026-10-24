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
