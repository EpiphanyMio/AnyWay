#ifndef AppVersion
  #define AppVersion "0.1.1"
#endif

[Setup]
AppId={{6E9EE0AA-C970-47CD-9E16-D4CBA61F3144}
AppName=AnyWay
AppVersion={#AppVersion}
AppPublisher=AnyWay
DefaultDirName={localappdata}\Programs\AnyWay
DefaultGroupName=AnyWay
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist\release
OutputBaseFilename=AnyWay-{#AppVersion}-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\WindowsLocationSimulator.exe

[InstallDelete]
Type: files; Name: "{app}\_internal\icuuc.dll"
Type: files; Name: "{app}\_internal\icudt78.dll"

[Files]
Source: "..\dist\WindowsLocationSimulator\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AnyWay"; Filename: "{app}\WindowsLocationSimulator.exe"
Name: "{autodesktop}\AnyWay"; Filename: "{app}\WindowsLocationSimulator.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\WindowsLocationSimulator.exe"; Description: "Launch AnyWay"; Flags: nowait postinstall skipifsilent

