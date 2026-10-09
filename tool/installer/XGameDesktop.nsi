; XGameDesktop 安装包（NSIS）
;
; 由 tool\package_windows.ps1 调用项目自带的便携版 NSIS 编译：
;   tool\nsis\makensis.exe /DVersion=… /DSrcDir=… /DOutFile=… /DRedist=… tool\installer\XGameDesktop.nsi
;
; 设计取向和其它部件一致：每用户安装（$LOCALAPPDATA\Programs），安装器自身不要求
; 管理员；用户数据始终由程序自己放在 %LOCALAPPDATA%\XGameDesktop，卸载时问一句
; 是否一起删除，默认保留。
; 程序本体 requireAdministrator（见 windows\runner\runner.exe.manifest）：启动时
; Windows 弹一次 UAC；因此关闭运行中的进程、开机自启动、完成页“立即运行”这几处
; 都要经 runas / ShellExecute 走一次授权，见下文各处注释。
;
; 输入（都有默认值，可单独用 makensis 编译调试）：
;   Version    版本号，来自 pubspec.yaml
;   SrcDir     已构建好的 Release 目录（package_windows.ps1 会先复制出一份干净副本）
;   OutFile    安装包输出路径
;   Redist     vc_redist.x64.exe 路径；不存在时跳过运行库安装
;   PawnIOSetup  PawnIO_setup.exe 路径（同目录有来源与哈希记录 PawnIO_setup.README）；
;              不存在时“硬件监控驱动”段为空，退回应用内的安装入口

Unicode true
!include "MUI2.nsh"
!include "LogicLib.nsh"

!ifndef Version
  !define Version "0.0.0"
!endif
!ifndef SrcDir
  !define SrcDir "..\..\build\windows\x64\runner\Release"
!endif
!ifndef OutFile
  !define OutFile "..\..\dist\XGameDesktop-Setup-${Version}.exe"
!endif

!define AppName "XGameDesktop"
!define ExeName "xgame_desktop.exe"
; 应用窗体的标题（windows\runner\main.cpp 里 Create 的那个），安装前用它找进程。
!define WindowTitle "xgame_desktop"
!define UninstKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\XGameDesktop"
!define Icon "${__FILEDIR__}\..\..\windows\runner\resources\app_icon.ico"

Name "${AppName} ${Version}"
OutFile "${OutFile}"
InstallDir "$LOCALAPPDATA\Programs\${AppName}"
InstallDirRegKey HKCU "Software\${AppName}" "InstallDir"
RequestExecutionLevel user
ShowInstDetails show
ShowUninstDetails show
SetCompressor /SOLID lzma
SetCompressorDictSize 64

VIProductVersion "${Version}.0"
VIAddVersionKey /LANG=2052 "ProductName" "${AppName}"
VIAddVersionKey /LANG=2052 "FileDescription" "${AppName} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${Version}"
VIAddVersionKey /LANG=2052 "ProductVersion" "${Version}"
VIAddVersionKey /LANG=2052 "CompanyName" "${AppName}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "${AppName}"

!define MUI_ICON "${Icon}"
!define MUI_UNICON "${Icon}"
!define MUI_ABORTWARNING
; requireAdministrator 的程序不能由完成页默认的 Exec（CreateProcess）启动——
; Windows 直接拒绝、连 UAC 都不弹；改走 ExecShell（ShellExecute → UAC 提权）。
; RUN 留空定义是开关，FUNCTION 才是实际执行的函数，缺一不可。
!define MUI_FINISHPAGE_RUN
!define MUI_FINISHPAGE_RUN_FUNCTION "LaunchAfterInstall"
!define MUI_FINISHPAGE_RUN_TEXT "立即运行 ${AppName}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

; 应用在跑就先把窗口关掉：文件被占用时 CopyFiles 会静默跳过，装出一份半新半旧的目录。
; 三级处理：先问，普通权限关不掉（提权后的窗口收不到低权限的 WM_CLOSE，UIPI 拦下）
; 就借 runas 的 taskkill 温柔关闭，再关不掉才让用户自己处理。/SD 保证 /S 静默安装
; 不会卡在对话框上。
!macro CloseRunningApp
  FindWindow $0 "" "${WindowTitle}"
  ${If} $0 != 0
    MessageBox MB_OKCANCEL|MB_ICONEXCLAMATION \
      "${AppName} 正在运行，继续之前需要先关闭它。" /SD IDOK IDOK closeOk
    Abort
    closeOk:
    SendMessage $0 ${WM_CLOSE} 0 0 /TIMEOUT=3000
    StrCpy $1 0
    ${While} $1 < 12
      Sleep 400
      FindWindow $0 "" "${WindowTitle}"
      ${If} $0 == 0
        ${Break}
      ${EndIf}
      IntOp $1 $1 + 1
    ${EndWhile}
    FindWindow $0 "" "${WindowTitle}"
    ${If} $0 != 0
      ExecShellWait "runas" "taskkill" "/im ${ExeName}" SW_HIDE
      StrCpy $1 0
      ${While} $1 < 12
        Sleep 400
        FindWindow $0 "" "${WindowTitle}"
        ${If} $0 == 0
          ${Break}
        ${EndIf}
        IntOp $1 $1 + 1
      ${EndWhile}
    ${EndIf}
    FindWindow $0 "" "${WindowTitle}"
    ${If} $0 != 0
      MessageBox MB_OK|MB_ICONSTOP "${AppName} 仍在运行，请手动关闭后重试。" /SD IDOK
      Abort
    ${EndIf}
  ${EndIf}
!macroend

Function .onInit
  !insertmacro CloseRunningApp
FunctionEnd

Function un.onInit
  !insertmacro CloseRunningApp
FunctionEnd

; 完成页“立即运行”：requireAdministrator 的 exe 要经 ShellExecute 走一次 UAC。
Function LaunchAfterInstall
  ExecShell "open" "$INSTDIR\${ExeName}"
FunctionEnd

; 运行库先行：Release 编译用动态 CRT，缺 MSVCP140 时程序连窗口都起不来。
; 检测用微软自己写的注册表标（x64 视图），缺了才运行安装包里的 vc_redist。
Section "-VC++ 运行库" SecVC
  !ifdef Redist
    SetRegView 64
    ReadRegDWORD $1 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
    SetRegView default
    ${If} $1 != 1
      InitPluginsDir
      SetOutPath "$PLUGINSDIR"
      File /oname=$PLUGINSDIR\vc_redist.x64.exe "${Redist}"
      DetailPrint "安装 Microsoft Visual C++ 运行库…"
      ExecWait '"$PLUGINSDIR\vc_redist.x64.exe" /install /quiet /norestart' $2
      ${If} $2 != 0
      ${AndIf} $2 != 3010
        MessageBox MB_OK|MB_ICONEXCLAMATION \
          "VC++ 运行库未能装好（代码 $2）。若 ${AppName} 启动时报缺少 DLL，请手动安装“Microsoft Visual C++ 2015-2022 可再发行组件 (x64)”。" \
          /SD IDOK
      ${EndIf}
      SetOutPath "$INSTDIR"
    ${EndIf}
  !endif
SectionEnd

Section "!${AppName}" SecApp
  SectionIn RO
  SetOutPath "$INSTDIR"
  ; Release 目录整棵拷进来：exe、flutter_windows.dll、各插件 DLL、data\。
  File /r "${SrcDir}\*"

  WriteUninstaller "$INSTDIR\uninstall.exe"

  CreateDirectory "$SMPROGRAMS\${AppName}"
  CreateShortCut "$SMPROGRAMS\${AppName}\${AppName}.lnk" "$INSTDIR\${ExeName}" "" "$INSTDIR\${ExeName}" 0

  ; 旧版用 Run 键做自启动；requireAdministrator 之后它再也带不起程序，装机即清。
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${AppName}"

  WriteRegStr HKCU "Software\${AppName}" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UninstKey}" "DisplayName" "${AppName}"
  WriteRegStr HKCU "${UninstKey}" "DisplayVersion" "${Version}"
  WriteRegStr HKCU "${UninstKey}" "DisplayIcon" "$INSTDIR\${ExeName}"
  WriteRegStr HKCU "${UninstKey}" "Publisher" "${AppName}"
  WriteRegStr HKCU "${UninstKey}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UninstKey}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UninstKey}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKCU "${UninstKey}" "NoModify" 1
  WriteRegDWORD HKCU "${UninstKey}" "NoRepair" 1
  WriteRegDWORD HKCU "${UninstKey}" "Language" 2052
SectionEnd

; 硬件监控驱动：hwprobe.dll 读温度/功耗/风扇靠 PawnIO 内核驱动，它必须注册成
; 系统服务（Windows 硬性规则），应用内的安装入口又要求用户碰巧打开监控面板，
; 新设备上很容易一直缺着。这里随安装包装好：官方签名安装器（未修改，见
; PawnIO_setup.README），runas 提权 + -install -silent，与 hwprobe.dll 内置
; 安装路径的行为完全一致；UAC 弹窗本身就是知情同意环节。
Section "硬件监控驱动 (PawnIO)" SecPawnIO
  !ifdef PawnIOSetup
    ; 服务已注册即视为已装（与应用内 hwprobe 的判定一致），不重复弹 UAC。
    SetRegView 64
    ClearErrors
    ReadRegStr $1 HKLM "SYSTEM\CurrentControlSet\Services\PawnIO" "ImagePath"
    SetRegView default
    ${IfNot} ${Errors}
      DetailPrint "PawnIO 已安装，跳过。"
      Return
    ${EndIf}

    InitPluginsDir
    SetOutPath "$PLUGINSDIR"
    File /oname=$PLUGINSDIR\PawnIO_setup.exe "${PawnIOSetup}"
    DetailPrint "安装 PawnIO 硬件监控驱动（需要管理员确认一次）…"
    ; runas 提权后由安装器完成服务注册；拒绝 UAC 时 ShellExecute 失败、置错误标志。
    ; showmode 只认 SW_* 字面量，不认数字。
    ExecShellWait "runas" "$PLUGINSDIR\PawnIO_setup.exe" "-install -silent" SW_HIDE

    ; 装没装成以服务是否存在为准，而不是安装器退出码（ExecShellWait 不给退出码）。
    SetRegView 64
    ClearErrors
    ReadRegStr $1 HKLM "SYSTEM\CurrentControlSet\Services\PawnIO" "ImagePath"
    SetRegView default
    ${If} ${Errors}
      DetailPrint "PawnIO 未能装上（可能跳过了管理员确认），温度/功耗/风扇暂不可用；之后可在应用的监控面板里再装。"
    ${Else}
      DetailPrint "PawnIO 硬件监控驱动安装完成。"
    ${EndIf}
  !endif
SectionEnd

Section "桌面快捷方式" SecDesktop
  CreateShortCut "$DESKTOP\${AppName}.lnk" "$INSTDIR\${ExeName}" "" "$INSTDIR\${ExeName}" 0
SectionEnd

Section /o "开机自动启动" SecStartup
  ; requireAdministrator 的程序不能从 Run 键自启动（登录时静默失败），改用计划
  ; 任务以最高权限在登录时启动，登录后不再弹 UAC；注册任务需要一次管理员确认。
  ExecShellWait "runas" "schtasks" '/create /f /tn "${AppName}" /tr "$\"$INSTDIR\${ExeName}$\"" /sc onlogon /rl highest' SW_HIDE
  ${If} ${Errors}
    MessageBox MB_OK|MB_ICONEXCLAMATION \
      "未获得管理员授权，开机自动启动没有设置。可以之后在安装包里重选，或手动创建。"
  ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecApp} "主程序、运行所需组件与开始菜单快捷方式。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecPawnIO} "安装 PawnIO 内核驱动（官方签名），用于温度、功耗与风扇读数；需要一次管理员确认。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "在桌面放一个 ${AppName} 图标。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecStartup} "登录 Windows 后自动启动 ${AppName}（计划任务，勾选时需要一次管理员确认）。"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
  ; PawnIO 是系统级共享驱动（别的工具也可能在用），卸载应用时不动它。
  ; 数据是用户自己攒的（壁纸、设置、常用统计），默认留着；只有明确点了“是”才删。
  IfSilent keepData
  MessageBox MB_YESNO|MB_ICONQUESTION \
    "是否同时删除配置、壁纸缓存等用户数据？$\n$\n$LOCALAPPDATA\${AppName}$\n$\n选择“否”将保留这些内容，重装后继续可用。" \
    /SD IDNO IDYES delData
  Goto keepData
  delData:
    RMDir /r "$LOCALAPPDATA\${AppName}"
  keepData:

  RMDir /r "$INSTDIR"
  Delete "$SMPROGRAMS\${AppName}\${AppName}.lnk"
  RMDir "$SMPROGRAMS\${AppName}"
  Delete "$DESKTOP\${AppName}.lnk"
  ; 自启动任务由提权的 schtasks 注册，同一用户通常能直接删；删不掉就留一条
  ; 指向已卸载路径的死任务，登录时静默失败，无害。
  nsExec::Exec 'schtasks /delete /f /tn "${AppName}"'
  Pop $0
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${AppName}"
  DeleteRegKey HKCU "${UninstKey}"
  DeleteRegKey HKCU "Software\${AppName}"
SectionEnd
