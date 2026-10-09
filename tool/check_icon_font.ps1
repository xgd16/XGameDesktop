<#
  校验构建产物里的图标字体真的含有代码里用到的字形。

  为什么要有这个脚本：flutter 构建 Release 时会把 MaterialIcons 裁成只含代码里用到的
  字形（--tree-shake-icons），而这一步属于“拷贝资源”。应用正在运行时它可能失败
  （package_windows.ps1 为了照顾被占用的 DLL，容忍了 flutter build 的非零退出码），
  增量构建也可能整个跳过 —— 两种情况的结果一样：data\app.so 是新的、字体还是上一轮
  裁出来的。界面表现是新增的图标一片空白（连方框都没有，字体的 cmap 里根本没这个码位），
  而构建本身只留一句警告，安装包照打不误。
  hwprobe.dll 那里已经用哈希挡住同类的“静默打进旧产物”，这里同样宁可中断。

  用法：
    powershell -ExecutionPolicy Bypass -File tool\check_icon_font.ps1 -FontPath <otf>
    ... -LibDir <源码目录>     扫哪里的 Icons.xxx（默认 <仓库>\lib）
    ... -IconsDart <icons.dart> 图标名到码位的对照表（默认从 flutter SDK 里找）

  退出码：0 = 全部命中；1 = 有缺失（缺失的名字会打出来）。
#>
param(
  [Parameter(Mandatory = $true)][string]$FontPath,
  [string]$LibDir,
  [string]$IconsDart
)

$ErrorActionPreference = 'Stop'

# 大端读取：字体里的偏移和码位都是网络字节序。
function Read-BeUInt16 {
  param([byte[]]$Bytes, [int]$Offset)
  return (([int]$Bytes[$Offset]) -shl 8) -bor [int]$Bytes[$Offset + 1]
}

function Read-BeUInt32 {
  param([byte[]]$Bytes, [int]$Offset)
  return (([int64]$Bytes[$Offset]) -shl 24) -bor (([int64]$Bytes[$Offset + 1]) -shl 16) `
       -bor (([int64]$Bytes[$Offset + 2]) -shl 8) -bor [int64]$Bytes[$Offset + 3]
}

# 从 cmap 里摊出所有“有字形”的码位。format 4 管 BMP，format 12 管 f00e9 这类
# 四位以上的码位（MaterialIcons 里不少），两种都要认。
function Get-FontCodepoints {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 12) { throw "字体文件不完整：$Path" }
  $tables = Read-BeUInt16 $bytes 4
  $cmap = -1
  for ($i = 0; $i -lt $tables; $i++) {
    $o = 12 + $i * 16
    if ($o + 16 -gt $bytes.Length) { break }
    $tag = [System.Text.Encoding]::ASCII.GetString($bytes, $o, 4)
    if ($tag -eq 'cmap') { $cmap = Read-BeUInt32 $bytes ($o + 8) }
  }
  if ($cmap -lt 0) { throw "字体里没有 cmap 表：$Path" }

  $set = New-Object 'System.Collections.Generic.HashSet[uint32]'
  $subs = Read-BeUInt16 $bytes ($cmap + 2)
  for ($i = 0; $i -lt $subs; $i++) {
    $base = $cmap + (Read-BeUInt32 $bytes ($cmap + 4 + $i * 8 + 4))
    if ($base + 2 -gt $bytes.Length) { continue }
    $format = Read-BeUInt16 $bytes $base
    if ($format -eq 4) {
      $segX2 = Read-BeUInt16 $bytes ($base + 6)
      $seg = [int]($segX2 / 2)
      $endsOff = $base + 14
      $startsOff = $endsOff + $segX2 + 2
      $deltasOff = $startsOff + $segX2
      $rangesOff = $deltasOff + $segX2
      for ($s = 0; $s -lt $seg; $s++) {
        $start = Read-BeUInt16 $bytes ($startsOff + $s * 2)
        $end = Read-BeUInt16 $bytes ($endsOff + $s * 2)
        $delta = Read-BeUInt16 $bytes ($deltasOff + $s * 2)
        $range = Read-BeUInt16 $bytes ($rangesOff + $s * 2)
        if ($start -gt $end) { continue }
        for ($c = $start; $c -le $end -and $c -ne 0xFFFF; $c++) {
          if ($rangesOff + $s * 2 + $range + ($c - $start) * 2 + 1 -ge $bytes.Length) { break }
          $gid = 0
          if ($range -eq 0) {
            $gid = ($c + $delta) -band 0xFFFF
          } else {
            $g = Read-BeUInt16 $bytes ($rangesOff + $s * 2 + $range + ($c - $start) * 2)
            if ($g -ne 0) { $gid = ($g + $delta) -band 0xFFFF }
          }
          if ($gid -ne 0) { [void]$set.Add([uint32]$c) }
        }
      }
    } elseif ($format -eq 12) {
      $groups = Read-BeUInt32 $bytes ($base + 12)
      for ($g = 0; $g -lt $groups; $g++) {
        $go = $base + 16 + $g * 12
        if ($go + 12 -gt $bytes.Length) { break }
        $sc = Read-BeUInt32 $bytes $go
        $ec = Read-BeUInt32 $bytes ($go + 4)
        for ($c = $sc; $c -le $ec; $c++) { [void]$set.Add([uint32]$c) }
      }
    }
  }
  return $set
}

# 图标名 → 码位。这份对照表就是 flutter 自己生成 icons.dart 的依据，直接读它，
# 免得在脚本里维护第二份名单。
function Get-IconCodepoints {
  param([string]$Path)
  $map = @{}
  $text = [System.IO.File]::ReadAllText($Path)
  foreach ($m in [regex]::Matches($text, 'static const IconData (\w+) = IconData\(\s*0x([0-9a-fA-F]+)')) {
    $map[$m.Groups[1].Value] = [uint32][Convert]::ToUInt32($m.Groups[2].Value, 16)
  }
  return $map
}

function Find-IconsDart {
  $roots = @()
  if ($env:FLUTTER_ROOT) { $roots += $env:FLUTTER_ROOT }
  $cmd = Get-Command flutter -ErrorAction SilentlyContinue
  if ($cmd) { $roots += (Split-Path -Parent (Split-Path -Parent $cmd.Source)) }
  foreach ($r in $roots) {
    $p = Join-Path $r 'packages\flutter\lib\src\material\icons.dart'
    if (Test-Path $p) { return $p }
  }
  return $null
}

if (-not (Test-Path $FontPath)) { throw "字体不存在：$FontPath" }
$root = Split-Path -Parent $PSScriptRoot
if (-not $LibDir) { $LibDir = Join-Path $root 'lib' }
if (-not (Test-Path $LibDir)) { throw "源码目录不存在：$LibDir" }

# 代码里出现的图标名。注释先去掉：注释里提一句某个图标名，不该要求字体里有它。
$used = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($file in Get-ChildItem $LibDir -Recurse -Filter '*.dart') {
  $code = [System.IO.File]::ReadAllText($file.FullName)
  $code = [regex]::Replace($code, '(?s)/\*.*?\*/', ' ')
  $code = [regex]::Replace($code, '//[^\r\n]*', '')
  foreach ($m in [regex]::Matches($code, 'Icons\.([A-Za-z][A-Za-z0-9_]*)')) {
    [void]$used.Add($m.Groups[1].Value)
  }
}

$iconsPath = if ($IconsDart) { $IconsDart } else { Find-IconsDart }
if (-not $iconsPath -or -not (Test-Path $iconsPath)) {
  Write-Warning "找不到 flutter SDK 里的 icons.dart，跳过字形校验（未校验：$($used.Count) 个图标）"
  exit 0
}

$known = Get-IconCodepoints $iconsPath
$have = Get-FontCodepoints $FontPath

$missing = @()
foreach ($name in $used) {
  # 对照表里没有的名字（注释残留、别的包的同名 API）不算数：真的拼错的话根本编译不过。
  if (-not $known.ContainsKey($name)) { continue }
  if (-not $have.Contains([uint32]$known[$name])) {
    $missing += ('{0} (0x{1:x})' -f $name, $known[$name])
  }
}

if ($missing.Count -gt 0) {
  Write-Host ''
  Write-Warning ("图标字体缺少 {0} 个字形：{1}" -f $missing.Count, (($missing | Sort-Object) -join '、'))
  Write-Warning "字体：$FontPath"
  Write-Warning '这是构建时“拷贝资源”那一步被跳过或失败留下的旧字体（data\app.so 是新的，字体不是）。'
  Write-Warning '先关掉正在运行的应用，再 `flutter clean` 重新构建（make clean 后重来）。'
  exit 1
}

Write-Host ("图标字体校验通过：{0} 个图标全部命中（字体里共 {1} 个码位）" -f $used.Count, $have.Count)
exit 0
