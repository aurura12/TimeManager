; time_manager Windows 安装包脚本（Inno Setup 6）
; 用法：
;   1. 先构建 release：flutter build windows --release
;   2. 用 Inno Setup 编译本脚本：
;      "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer.iss
;   3. 产物：installer_output\time_manager_setup_<版本>.exe
;   4. 上传到 Gitee time_manager_releases 仓库 release 资产（tag 与版本一致）
;
; 版本号需与 pubspec.yaml 的 version 保持一致（只取前三段，如 1.84.0+1 → 1.84.0）

#define MyAppName "time_manager"
#define MyAppVersion "1.85.0"
#define MyAppPublisher "time_manager"
#define MyAppExeName "time_manager.exe"
; Flutter Windows release 产物目录
#define MyReleaseDir "build\windows\x64\runner\Release"

[Setup]
; 应用唯一标识（GUID，勿与其他应用重复）
AppId={{8F6B3C1E-4A2D-4C7B-9E5A-3D2F1B8C6E47}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; 安装到 Program Files 需要管理员权限，Inno Setup 会自动触发 UAC
PrivilegesRequired=admin
OutputDir=installer_output
OutputBaseFilename=time_manager_setup_{#MyAppVersion}
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; 仅支持 64 位 Windows（Flutter Windows 默认 x64 构建）
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 卸载时移除开始菜单/桌面快捷方式
UninstallDisplayName={#MyAppName}

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 递归复制整个 Release 目录（exe + dll + data 等）
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

; 卸载前确保应用未运行，避免删除被占用文件
[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /f /im ""{#MyAppExeName}"" >nul 2>&1"; Flags: runhidden
