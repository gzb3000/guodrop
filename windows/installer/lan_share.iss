; Inno Setup 安装脚本 —— 由 .github/workflows/release.yml 调用
;   iscc /DAppVersion=0.2.0 /DSourceDir=build\windows\x64\runner\Release windows\installer\lan_share.iss
; 产物：build\installer\guodrop-windows-setup.exe（文件名与自动更新地址一致，勿改）
;
; 用户级安装（无需管理员）：%LOCALAPPDATA%\Programs\lan_share
; App 内自动更新会以 /SILENT /CLOSEAPPLICATIONS 运行本安装器，装完自动重启 App。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6F2B7C1E-4A1D-4E8B-9C35-1A2B3C4D5E6F}
AppName=局域网传输
AppVersion={#AppVersion}
AppPublisher=lan_share
DefaultDirName={localappdata}\Programs\lan_share
DefaultGroupName=局域网传输
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
OutputDir=..\..\build\installer
OutputBaseFilename=guodrop-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
RestartApplications=no
UninstallDisplayIcon={app}\lan_share.exe
WizardStyle=modern

[Languages]
Name: "chs"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\局域网传输"; Filename: "{app}\lan_share.exe"
Name: "{autodesktop}\局域网传输"; Filename: "{app}\lan_share.exe"; Tasks: desktopicon

[Run]
; 静默更新（/SILENT）时也会执行：装完自动启动新版
Filename: "{app}\lan_share.exe"; Description: "{cm:LaunchProgram,局域网传输}"; Flags: nowait postinstall
