; A股选股台 Windows 安装包脚本
; 用法：先 flutter build windows --release，再执行
;   ISCC.exe windows\installer.iss
; 产物：build\installer\AStock-<版本>-Windows-Setup.exe

#define AppVersion "2.7.0"
#define AppName "A股选股台"
#define ExeName "ASTock"

[Setup]
AppId={{7A3C2E91-4B6D-4F8A-9C05-2E1D73B80A46}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
DefaultDirName={autopf}\{#ExeName}
DefaultGroupName={#AppName}
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#ExeName}.exe
SetupIconFile=runner\resources\app_icon.ico
OutputDir=..\build\installer
OutputBaseFilename=AStock-{#AppVersion}-Windows-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
ShowLanguageDialog=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式(&D)"; GroupDescription: "附加任务："; Flags: checkedonce

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#ExeName}.exe"
Name: "{group}\卸载 {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}.exe"; Description: "运行 {#AppName}"; Flags: nowait postinstall skipifsilent
