<#
  打包 XGameDesktop 的 Windows 安装包（单文件 Setup.exe）。

  用法（在项目根目录或任意位置都行）：
    powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1
    powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1 -SkipBuild     # 复用已有 Release 产物
    powershell -ExecutionPolicy Bypass -File tool\package_windows.ps1 -Version 1.2.0 # 覆盖版本号

  产物：dist\XGameDesktop-Setup-<版本>.exe

  工具链自带，不要求机器上装任何东西：NSIS 便携版在 tool\nsis\（makensis.exe）。
  重装/更新它：从 https://sourceforge.net/projects/nsis/files/NSIS%203/<版本>/nsis-<版本>.zip
  下载后解到 tool\nsis\，删掉 Docs / Examples 即可（3.13 的 zip sha256 ba63dffc…）。
  安装包内的 vc_redist.x64.exe 取自本机 Visual Studio 的 VC\Redist，缺了也能编，
  只是安装时不再补运行库。PawnIO 驱动安装器随仓库放在 tool\installer\（来源与
  哈希见 PawnIO_setup.README），缺了也能编，只是安装时不再自动装驱动。
#>
param(
  [switch]$SkipBuild,
  [string]$Version,
  [string]$DistDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $Version) {
  $m = Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([0-9]+(?:\.[0-9]+)*)' |
       Select-Object -First 1
  if (-not $m) { throw 'pubspec.yaml 里找不到 version:' }
  $Version = $m.Matches[0].Groups[1].Value
}
if (-not $DistDir) { $DistDir = Join-Path $root 'dist' }

$makensis = Join-Path $root 'tool\nsis\makensis.exe'
if (-not (Test-Path $makensis)) {
  throw "缺少 NSIS：$makensis（见本脚本头部注释里的下载地址）"
}

if (-not $SkipBuild) {
  Write-Host "构建 Release…"
  & flutter build windows --release
  # 应用正在运行时，最后几步拷贝 DLL 会失败，但 Dart 代码（data\app.so）已经编好；
  # 此时目录内容仍然完整，继续打包即可。
  if ($LASTEXITCODE -ne 0) { Write-Warning "flutter build 退出码 $LASTEXITCODE，继续用现有产物打包。" }
}

$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'xgame_desktop.exe'))) {
  throw "Release 产物不存在：$release"
}

# CMake 把 native\hwprobe.dll 装进 Release 的那一步，只在 Flutter 真正重新构建时才会跑；
# 源码没变时 flutter build 会整体跳过，Release 里的 DLL 就会停在旧版本，静默打进安装包。
# 这里按内容比对刷新一次。应用运行时（exe 已加载该 DLL）Release 那份会被锁住，不致命——
# 真正进包的是下面 stage 里的副本，那里再兜一次底。
$hwprobeSrc = Join-Path $root 'native\hwprobe.dll'
if (-not (Test-Path $hwprobeSrc)) { throw "缺少硬件监控 DLL：$hwprobeSrc" }
$hwprobeDst = Join-Path $release 'hwprobe.dll'
if (-not (Test-Path $hwprobeDst) -or
    (Get-FileHash $hwprobeSrc).Hash -ne (Get-FileHash $hwprobeDst).Hash) {
  try {
    Copy-Item $hwprobeSrc $hwprobeDst -Force -ErrorAction Stop
    Write-Host '已刷新 Release 里的 hwprobe.dll'
  } catch {
    Write-Warning "Release 里的 hwprobe.dll 被占用，跳过（应用还在运行？）：$($_.Exception.Message)"
  }
}

# 图标字体：flutter 会把 MaterialIcons 裁成只含代码里用到的字形（--tree-shake-icons），
# 和 hwprobe.dll 一样，这一步也在“拷贝资源”里 —— 上面那个非零退出码是被容忍的（应用在跑时
# DLL 拷不动），而资源拷贝失败或增量构建把它整个跳过时，data\app.so 是新的、字体还是上一轮
# 裁出来的：新增的图标在界面上是一片空白（cmap 里根本没那个码位），构建只留一句警告。
# 所以进包之前按源码里用到的图标名核对一遍字形，缺一个就中断。
$iconFont = Join-Path $release 'data\flutter_assets\fonts\MaterialIcons-Regular.otf'
& powershell -NoProfile -ExecutionPolicy Bypass -File `
  (Join-Path $root 'tool\check_icon_font.ps1') -FontPath $iconFont
if ($LASTEXITCODE -ne 0) {
  throw "图标字体与源码不一致（缺字形），已中止打包：$iconFont"
}

# 先摊出一份干净副本：<exe名>.WebView2 是 WebView2 运行时跑起来后自己建的缓存，不能进安装包。
$stage = Join-Path $root 'build\installer\stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $release '*') $stage -Recurse -Force
Get-ChildItem $stage -Directory -Filter '*.WebView2' | Remove-Item -Recurse -Force
Get-ChildItem $stage -Recurse -Include '*.log', '*.pdb' | Remove-Item -Force -ErrorAction SilentlyContinue

# 进包的那份 DLL 必须等于 native\hwprobe.dll。stage 不受运行中的应用占用，这里直接覆盖并
# 校验哈希：对不上就中断——宁可打不出包，也不能把旧 DLL 静默打进安装包。
Copy-Item $hwprobeSrc (Join-Path $stage 'hwprobe.dll') -Force -ErrorAction Stop
if ((Get-FileHash $hwprobeSrc).Hash -ne (Get-FileHash (Join-Path $stage 'hwprobe.dll')).Hash) {
  throw '暂存目录里的 hwprobe.dll 与 native\hwprobe.dll 不一致。'
}

# VC++ 运行库：优先用本机 VS 自带的再发行包，装到缺运行库的机器上时由安装程序按需运行。
# 两个根都试：从 make 里跑时整条链是 32 位的（便携版 make.exe 是 32 位），WOW64 会把
# ProgramFiles 改写成 "C:\Program Files (x86)"，只认它就会漏掉 64 位的 VS 安装。
$redist = $null
$vsRoots = @($env:ProgramW6432, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique
foreach ($vsRoot in $vsRoots) {
  $redist = Get-ChildItem "$vsRoot\Microsoft Visual Studio\*\*\VC\Redist\MSVC\*\vc_redist.x64.exe" `
    -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
  if ($redist) { break }
}
if (-not $redist) {
  Write-Warning '没找到 vc_redist.x64.exe（Visual Studio 的 VC\Redist 下），安装包将不包含运行库。'
}

# PawnIO 硬件监控驱动：随包自带官方签名安装器（来源与哈希见 PawnIO_setup.README），
# 安装包的“硬件监控驱动”段用它静默装驱动；丢失时降级为不装，应用内的安装入口仍在。
$pawnio = Join-Path $root 'tool\installer\PawnIO_setup.exe'
if (-not (Test-Path $pawnio)) {
  Write-Warning "缺少 PawnIO_setup.exe（$pawnio），安装包将不包含硬件监控驱动。"
}

if (-not (Test-Path $DistDir)) { New-Item -ItemType Directory -Force $DistDir | Out-Null }
$out = Join-Path $DistDir "XGameDesktop-Setup-$Version.exe"
if (Test-Path $out) { Remove-Item -Force $out }

$nsisArgs = @(
  "/DVersion=$Version",
  "/DSrcDir=$stage",
  "/DOutFile=$out",
  (Join-Path $root 'tool\installer\XGameDesktop.nsi')
)
if ($redist) { $nsisArgs = @("/DRedist=$($redist.FullName)") + $nsisArgs }
if (Test-Path $pawnio) { $nsisArgs = @("/DPawnIOSetup=$pawnio") + $nsisArgs }

Write-Host "编译安装包…"
& $makensis $nsisArgs | Write-Host
if ($LASTEXITCODE -ne 0) { throw "makensis 失败（退出码 $LASTEXITCODE）" }

$size = [math]::Round((Get-Item $out).Length / 1MB, 1)
Write-Host ""
Write-Host "安装包：$out（$size MB）"
