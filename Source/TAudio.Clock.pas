unit TAudio.Clock;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}

{
  High-resolution monotonic time for audio timestamps.

  On Windows this is QueryPerformanceCounter, the clock WASAPI uses for the
  u64QPCPosition of captured packets (in 100 ns units), so capture timestamps and
  AudioMonotonicUs compare directly. Elsewhere it is CLOCK_MONOTONIC.
}

interface

// Microseconds since an arbitrary fixed point (system boot on Windows and Linux).
function AudioMonotonicUs: Int64;
// WASAPI QPC positions are in 100 ns units of the same counter.
function AudioQpcHnsToUs(Hns: UInt64): Int64; inline;

implementation

{$IFDEF MSWINDOWS}
uses
{$IFDEF FPC}
  Windows;
{$ELSE}
  Winapi.Windows;
{$ENDIF}

var
  QpcFrequency: Int64 = 0;

function AudioMonotonicUs: Int64;
var
  Counter: Int64;
begin
  if QpcFrequency = 0 then
    QueryPerformanceFrequency(QpcFrequency);
  QueryPerformanceCounter(Counter);
  // Split to avoid overflow: Counter * 1e6 exceeds Int64 after ~10 days at 10 MHz.
  Result:=(Counter DIV QpcFrequency) * 1000000 + ((Counter MOD QpcFrequency) * 1000000) DIV QpcFrequency;
end;
{$ELSE}
uses
  Unix, BaseUnix, Linux;

function AudioMonotonicUs: Int64;
var
  T: TTimeSpec;
begin
  clock_gettime(CLOCK_MONOTONIC, @T);
  Result:=Int64(T.tv_sec) * 1000000 + T.tv_nsec DIV 1000;
end;
{$ENDIF}

function AudioQpcHnsToUs(Hns: UInt64): Int64;
begin
  Result:=Int64(Hns DIV 10);
end;

end.
