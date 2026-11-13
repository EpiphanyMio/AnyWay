#ifndef AppVersion
  #error AppVersion must be supplied from the root VERSION file
#endif

[Setup]
AppId={{6E9EE0AA-C970-47CD-9E16-D4CBA61F3144}
AppName=AnyWay
AppVersion={#AppVersion}
AppPublisher=AnyWay
DefaultDirName={localappdata}\Programs\AnyWay
UsePreviousAppDir=no
DefaultGroupName=AnyWay
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist\release
OutputBaseFilename=AnyWay-{#AppVersion}-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\assets\app-icon.ico
UninstallDisplayIcon={app}\AnyWay.exe

[InstallDelete]
Type: files; Name: "{app}\WindowsLocationSimulator.exe"
Type: filesandordirs; Name: "{app}\_internal"
Type: filesandordirs; Name: "{app}\runtime"

[Files]
Source: "..\dist\AnyWay\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AnyWay"; Filename: "{app}\AnyWay.exe"; IconFilename: "{app}\AnyWay.exe"
Name: "{autodesktop}\AnyWay"; Filename: "{app}\AnyWay.exe"; IconFilename: "{app}\AnyWay.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Run]
Filename: "{app}\AnyWay.exe"; Description: "Launch AnyWay"; Flags: nowait postinstall skipifsilent

