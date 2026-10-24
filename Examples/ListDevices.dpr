program ListDevices;

{$APPTYPE CONSOLE}

uses
  System.SysUtils, TAudio.Types, TAudio.Output.WASAPI;

var
  Device: TAudioDeviceInfo;
begin
  try
    for Device IN TAudioOutputWASAPI.EnumerateDevices do
    begin
      WriteLn(Device.FriendlyName, ' [', Device.StateText, '] default=', Device.IsDefault);
      WriteLn('  ', Device.Id);
    end;
  except
    on E: Exception do
    begin
      WriteLn(E.Message);
      ExitCode:=1;
    end;
  end;
end.
