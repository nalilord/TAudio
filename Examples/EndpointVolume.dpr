program EndpointVolume;

{$IFDEF FPC}{$MODE DELPHI}{$H+}{$ENDIF}
{$APPTYPE CONSOLE}

{
  Shows or sets the master volume and mute of WASAPI endpoints.

    EndpointVolume                       list render and capture endpoints
    EndpointVolume <name> <0..100>       set the volume of the first matching endpoint and unmute it
}

uses
{$IFDEF FPC}
  Windows, ActiveX, SysUtils,
{$ELSE}
  Winapi.Windows, Winapi.ActiveX, System.SysUtils,
{$ENDIF}
  TAudio.Windows;

procedure Check(HR: HResult; const What: string);
begin
  if Failed(HR) then
    raise Exception.CreateFmt('%s failed (0x%.8x)', [What, Cardinal(HR)]);
end;

var
  Enumerator: IMMDeviceEnumerator;
  Collection: IMMDeviceCollection;
  Device: IMMDevice;
  Unknown: IUnknown;
  Volume: IAudioEndpointVolume;
  Count, I: UINT;
  Flow: Integer;
  Name, Needle: string;
  Level: Single;
  Muted: BOOL;
  Target: Integer;
  Done: Boolean;
begin
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
    Needle:='';
    Target:=-1;
    if ParamCount >= 2 then
    begin
      Needle:=LowerCase(ParamStr(1));
      Target:=StrToInt(ParamStr(2));
    end;
    Done:=False;
    Check(CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL, IID_IMMDeviceEnumerator, Enumerator), 'CoCreateInstance');
    for Flow:=eRender to eCapture do
    begin
      Check(Enumerator.EnumAudioEndpoints(Flow, 1, Collection), 'EnumAudioEndpoints');
      Check(Collection.GetCount(Count), 'GetCount');
      if Count = 0 then
        Continue;
      for I:=0 to Count - 1 do
      begin
        Check(Collection.Item(I, Device), 'Item');
        Name:=AudioDeviceProperty(Device, '{A45C254E-DF1C-4EFD-8020-67D146A850E0}', 14);
        if Failed(Device.Activate(IID_IAudioEndpointVolume, CLSCTX_ALL, nil, Unknown)) then
          Continue;
        Volume:=Unknown AS IAudioEndpointVolume;
        if (Needle <> '') AND NOT Done AND (Pos(Needle, LowerCase(Name)) > 0) then
        begin
          Check(Volume.SetMasterVolumeLevelScalar(Target / 100, nil), 'SetMasterVolumeLevelScalar');
          Check(Volume.SetMute(False, nil), 'SetMute');
          Done:=True;
          Writeln('SET ', Name, ' -> ', Target, '%, unmuted');
        end;
        Volume.GetMasterVolumeLevelScalar(Level);
        Volume.GetMute(Muted);
        if Flow = eRender then
          Write('render  ')
        else
          Write('capture ');
        Writeln(Format('%3.0f%% %s  %s', [Level * 100, BoolToStr(Muted, True), Name]));
      end;
    end;
    if (Needle <> '') AND NOT Done then
    begin
      Writeln('No endpoint matches "', ParamStr(1), '"');
      ExitCode:=1;
    end;
  except
    on E: Exception do
    begin
      Writeln('ERROR ', E.Message);
      ExitCode:=1;
    end;
  end;
end.
