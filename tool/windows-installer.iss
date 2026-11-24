; The per-user Windows installer, which is also the update WinSparkle runs
; (windows/runner/updates.h, appcast from tool/release.ts). Built by
; tool/package-windows.ps1. Keep AppId: installed copies upgrade by it.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef Payload
  #error Payload is required
#endif

[Setup]
AppId={{6F4B7C1E-2D8A-4E5B-9C3F-1A7D0E2B8C46}
AppName=ListenJar
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=ListenJar
AppPublisherURL=https://listenjar.com/
AppSupportURL=https://github.com/listenjar/desktop/issues
AppUpdatesURL=https://github.com/listenjar/desktop/releases
DefaultDirName={localappdata}\Programs\ListenJar
DefaultGroupName=ListenJar
PrivilegesRequired=lowest
DisableDirPage=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; The running app holds this mutex (windows/runner/instance.h).
AppMutex=Local\ListenJar
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\listenjar.exe
OutputDir=..\build\release
OutputBaseFilename=ListenJar-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\ListenJar"; Filename: "{app}\listenjar.exe"

[Run]
Filename: "{app}\listenjar.exe"; Description: "Open ListenJar"; Flags: nowait postinstall skipifsilent
; An update runs silently: open the new version where the old one closed.
Filename: "{app}\listenjar.exe"; Flags: nowait; Check: WizardSilent

[Code]
function GetTickCount64: Int64;
  external 'GetTickCount64@kernel32.dll stdcall';

// WinSparkle starts this installer, then asks the app to quit: give it a
// minute to close before giving up, never kill it.
function InitializeSetup: Boolean;
var
  Deadline: Int64;
begin
  Deadline := GetTickCount64 + 60000;
  while CheckForMutexes('Local\ListenJar') and (GetTickCount64 < Deadline) do
    Sleep(100);
  Result := not CheckForMutexes('Local\ListenJar');
  if not Result then
    MsgBox('ListenJar is still open. Quit it from the tray icon, then run this installer again.', mbError, MB_OK);
end;
