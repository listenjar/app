; The per-user Windows installer, which is also the update WinSparkle runs
; (windows/runner/updates.h, appcast from tool/release.ts). Built by
; tool/package-windows.ps1, once per architecture. Keep AppId, shared by both:
; installed copies upgrade by it.
#ifndef Arch
  #error Arch is required: x64 or arm64
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef Payload
  #error Payload is required
#endif

[Setup]
AppId={{6F4B7C1E-2D8A-4E5B-9C3F-1A7D0E2B8C46}
AppName=Listenjar
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
AppPublisher=Listenjar
AppPublisherURL=https://listenjar.com/
AppSupportURL=https://github.com/listenjar/app/issues
AppUpdatesURL=https://github.com/listenjar/app/releases
DefaultDirName={localappdata}\Programs\Listenjar
DefaultGroupName=Listenjar
PrivilegesRequired=lowest
DisableDirPage=yes
DisableProgramGroupPage=yes
; x64 also installs on Windows 11 on Arm, which emulates it.
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0
; The running app holds this mutex (windows/runner/instance.h); builds from
; before the rename to Listenjar hold Local\ListenJar, mutex names being
; case-sensitive.
AppMutex=Local\Listenjar,Local\ListenJar
CloseApplications=no
RestartApplications=no
UninstallDisplayIcon={app}\listenjar.exe
OutputDir=..\build\release
OutputBaseFilename=Listenjar-{#AppVersion}-windows-{#Arch}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#Payload}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Listenjar"; Filename: "{app}\listenjar.exe"

[Run]
Filename: "{app}\listenjar.exe"; Description: "Open Listenjar"; Flags: nowait postinstall skipifsilent
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
  while CheckForMutexes('Local\Listenjar,Local\ListenJar') and (GetTickCount64 < Deadline) do
    Sleep(100);
  Result := not CheckForMutexes('Local\Listenjar,Local\ListenJar');
  if not Result then
    MsgBox('Listenjar is still open. Quit it from the tray icon, then run this installer again.', mbError, MB_OK);
end;
