; Inno Setup 安装脚本 —— 由 .github/workflows/release.yml 调用
;   iscc /DAppVersion=0.2.0 /DSourceDir=build\windows\x64\runner\Release windows\installer\lan_share.iss
; 产物：build\installer\guodrop-windows-setup.exe（文件名与自动更新地址一致，勿改）
;
; 用户级安装（无需管理员）：%LOCALAPPDATA%\Programs\GUODROP（老用户沿用 lan_share 目录）
; 0.2.0 起的 App 内自动更新会以 /SILENT /CLOSEAPPLICATIONS 运行本安装器，装完自动重启 App。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6F2B7C1E-4A1D-4E8B-9C35-1A2B3C4D5E6F}
AppName=GUODROP
AppVersion={#AppVersion}
AppPublisher=GUODROP
; 新装默认目录 GUODROP；从 0.2.0（同一 AppId）升级时 Inno 会沿用旧目录
; （%LOCALAPPDATA%\Programs\lan_share），这是有意的：静默升级原地覆盖最稳妥。
DefaultDirName={localappdata}\Programs\GUODROP
UsePreviousAppDir=yes
UsePreviousGroup=no
DefaultGroupName=GUODROP
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
UninstallDisplayIcon={app}\GUODROP.exe
UninstallDisplayName=GUODROP
WizardStyle=modern

[Languages]
Name: "chs"; MessagesFile: "ChineseSimplified.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; 清理 0.2.0 及更早版本（exe 名 lan_share.exe、快捷方式名「局域网传输」）
Type: files; Name: "{app}\lan_share.exe"
Type: files; Name: "{autodesktop}\局域网传输.lnk"
Type: filesandordirs; Name: "{autoprograms}\局域网传输"
Type: files; Name: "{autoprograms}\局域网传输.lnk"

[Icons]
Name: "{group}\GUODROP"; Filename: "{app}\GUODROP.exe"
Name: "{autodesktop}\GUODROP"; Filename: "{app}\GUODROP.exe"; Tasks: desktopicon

[Run]
; 静默更新（/SILENT）时也会执行：装完自动启动新版
Filename: "{app}\GUODROP.exe"; Description: "{cm:LaunchProgram,GUODROP}"; Flags: nowait postinstall
