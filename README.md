# XGame Desktop

> 一个把手柄当主输入、把 Windows 桌面当游戏机的客厅前端。
> 手柄导航的应用启动器 + 实时硬件遥测 + 系统级动态壁纸。

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4?logo=windows&logoColor=white)](#前置要求)
[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-%5E3.13.5-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-269%20passing-brightgreen)](#测试)

---

## 目录

- [这是什么](#这是什么)
- [功能](#功能)
- [截图](#截图)
- [前置要求](#前置要求)
- [构建与运行](#构建与运行)
- [打包 Windows 安装包](#打包-windows-安装包)
- [手柄按键映射](#手柄按键映射)
- [硬件监控后端](#硬件监控后端)
- [动态壁纸系统](#动态壁纸系统)
- [架构](#架构)
- [数据目录与注册表](#数据目录与注册表)
- [测试](#测试)
- [已知限制](#已知限制)
- [第三方组件与许可](#第三方组件与许可)
- [参与贡献](#参与贡献)

---

## 这是什么

XGame Desktop 是一个 Windows 桌面外壳(desktop shell),目标是把一台接电视/显示器的
PC 用成游戏机:

- **手柄优先**。方向键/D-pad/左摇杆就能走完整个界面,鼠标、键盘、触摸屏同样可用 ——
  每个控件都同时响应这四种输入,没有"只能点"的死角。
- **开箱即用的应用启动器**。自动扫描开始菜单和 Steam 库,抽出图标和封面,
  按 游戏 / 应用 / 开发 / 系统 分类,支持模糊搜索、固定、使用统计与最近启动排序。
- **实时硬件遥测**。CPU/GPU/内存/硬盘/网络/电池/风扇的温度、功耗、占用、频率,
  以及 1 小时到 7 天的历史曲线 —— 由独立的 [`hwprobe`](https://github.com/xgd16/hwprobe)
  硬件信息库(DLL,ABI 4)提供数据。
- **系统级动态壁纸**。静态图片、视频、网页、Wallpaper Engine 的场景包四类背景,
  沉浸模式下整窗无边框、任务栏融入背景,像一台真正的游戏机前端。

界面文字目前全部是简体中文且硬编码(没有接入 `intl`)。

## 功能

### 应用与应用库

| 功能 | 说明 | 实现 |
| --- | --- | --- |
| 开始菜单扫描 | 遍历所有用户 + 当前用户的开始菜单,`跳过 Startup`,`.lnk`/`.url`,按小写名去重 | [shell_apps.dart](lib/native/shell_apps.dart) |
| 桌面快捷方式叠加 | 合并只存在于桌面的快捷方式,并标记"桌面上也有";剥掉 Windows 的 `" - 快捷方式"` 后缀 | `shell_apps.dart` |
| Steam 库扫描 | 直接解析 `steamapps\appmanifest_*.acf`(`StateFlags` bit 3 = 已完整安装),过滤运行时/Proton/创意工具,用 `steam://rungameid/<id>` 启动 | [steam_games.dart](lib/native/steam_games.dart) |
| 封面获取 | 优先本地 `appcache\librarycache`,缺失时每个游戏每次会话只试一次 Steam CDN,缓存到数据目录;离线时退回首字母色块 | `steam_games.dart`、[apps_provider.dart](lib/state/apps_provider.dart) |
| 图标提取 | COM `IShellItemImageFactory` 96px,带墨迹覆盖率启发式(避免拿到空心的 48px 大图标框),回退 `ExtractIconEx`/`SHGetFileInfo`;BGRA→PNG 并做反预乘与 1bpp 掩码透明 | [icon_extract.dart](lib/native/icon_extract.dart)、[bgra_png.dart](lib/native/bgra_png.dart) |
| 模糊搜索 | 分级打分:精确 1000 > 前缀 860 > 词首 800 > 首字母缩写 770/730 > 子串 700 > 全词匹配 560 > 跳跃子序列 500;全角转 ASCII | [search_index.dart](lib/state/search_index.dart) |
| 固定与排序 | 固定在每个视图置顶,可上移/下移,卡片带角标 | [app_activity_store.dart](lib/data/app_activity_store.dart) |
| 使用统计 | 启动次数、首次/末次启动、排名、与领先者的对比条、占比、相对时间,支持清空(两次确认) | [stats_page.dart](lib/ui/stats_page.dart) |
| 右键菜单 | 打开 / 固定 / 取消固定 / 上移 / 下移 / 打开文件位置 / 复制路径 | [context_menu.dart](lib/ui/context_menu.dart) |
| 旧配置导入 | 一次性读取迁移前的 `usage.json` / `pins.json` | [legacy_app_import.dart](lib/state/legacy_app_import.dart) |

### 界面与交互

- **无边框窗口 + 自绘标题栏**:`WM_NCCALCSIZE` 把整个矩形让给客户区,同时保留
  `WS_THICKFRAME` 以保住原生缩放和 Aero Snap;顺手屏蔽 `WM_NCACTIVATE`/`WM_NCPAINT`
  消除 DWM 标题闪烁。DWM 深色模式跟随系统 `AppsUseLightTheme`。
- **沉浸模式**:整个外壳按 1600px 名义宽度布局后 `FittedBox` 放大到屏幕,而不是重新排版;
  原生侧是无边框弹窗铺满显示器,可只差底部 1 像素以躲开"全屏"判定、让任务栏留在最上层,
  并通过 `SetWindowCompositionAttribute` 把任务栏底色改成透明渐变。F11 或手柄 View 切换。
- **启动画面**:目录、搜索索引、图标加载期间覆盖外壳,带真实分阶段进度,任意按键/点击/手柄键可跳过。
- **焦点自愈**:焦点控件消失后,外壳会把高亮交还给同一网格位置、首个卡片、搜索框或软键盘。
- **手柄提示浮层**:检测到手柄时自动出现按键说明,4 秒后淡出。
- **软键盘**:浮在网格下半部(结果仍可见),`1234567890 / QWERTYUIOP / ASDFGHJKL / ZXCVBNM`,
  每个键一个 `FocusNode` 且导航是手写的 —— 框架的遍历会去查窗口里所有可聚焦节点(包括遥测栏)。
- **四套配色**:竞技紫 `#8B7CFF`(默认)、电光蓝 `#4F8CFF`、荧光青 `#22D3EE`、熔岩橙 `#FF6B4A`,
  切换经 `AnimatedTheme` 350ms 缓动。
- **磨砂面板**:`BackdropFilter`,或者对静态壁纸烘焙一次半分辨率预模糊副本让玻璃面板只读纹理 ——
  后者是因为整窗 24px 高斯模糊是静态壁纸对 GPU 最贵的一项开销。
- **单实例**:命名互斥体 `Local\XGameDesktop.SingleInstance`,第二次启动只是把已有窗口带到前台。

### 硬件遥测

- 右侧 384px 遥测栏:时钟+天气、CPU(占用 hero/频率/温度/功耗)、GPU(占用/温度/功耗/显存)、
  风扇、内存(占用/功耗/用量 + SMBIOS 摘要)、电池、网络(收发曲线)、存储(卷 + 物理盘)。
- 完整监控页:1 小时 / 6 小时 / 24 小时 / 7 天四档范围,11 张图表卡片(CPU/GPU 占用、温度、功耗、
  内存占用率、内存用量、显存用量、CPU 频率、网络速率、磁盘活动、磁盘吞吐、风扇转速),
  每张显示最新值与均值/峰值。
- 采样间隔 1/2/3/5/10/30 秒;历史保留 7 天;历史库是独立的 `metrics.db`,删掉只损失读数。

### 天气与时钟

无需 API Key:按顺序尝试 `ip-api.com` → `ipwho.is` → `ipapi.co` 定位,再用 Open-Meteo 取当前与当日
最高/最低温;每 30 分钟刷新、失败 3 分钟后重试,已有读数只标记为过期而不清空。时钟与日期为手写格式化
(不引入 `intl`)。

### 电源与生命周期

`AppActivity.visible` 是唯一的可见性闸门:1Hz 遥测轮询、手柄轮询、视频解码、时钟、历史记录、
天气定时器全部挂在它下面,窗口不可见时一律停下。**低功耗档**(自动跟随电池 / 开 / 关三态)把背景模糊
压到 8px、场景壁纸帧率压到 15,并关掉装饰性动画;"自动"在检测到电池的机器(掌机/笔记本)上默认开启。

## 截图

> 截图待补充。欢迎提 PR 附上你的主题配色与壁纸。
>
> 建议同时提供:应用网格、监控面板、完整监控页、设置页、沉浸模式。

## 前置要求

| 项 | 要求 |
| --- | --- |
| 系统 | Windows 10/11 x64 |
| Flutter | 3.44+(`.metadata` 锁定的 tools revision 为 `5fc346839b`,开发时为 Flutter 3.47.6 / Dart 3.13.5) |
| Dart SDK | `^3.13.5`(见 [pubspec.yaml](pubspec.yaml)) |
| Visual Studio | 需勾选 **使用 C++ 的桌面开发** 工作负载(CMake ≥ 3.14 + MSVC) |
| GNU make | 可选,想用 `make` 目标才需要。没有 make 也可以直接调 `flutter` 与 `tool\package_windows.ps1` |
| NSIS 3 | 只有打安装包需要。装好后确保 `makensis.exe` 在 `PATH`,或放到 `tool\nsis\makensis.exe` |

`hwprobe.dll`(硬件监控后端)不在仓库里,详见[硬件监控后端](#硬件监控后端) —— 不装也能正常使用,
只是没有遥测数据。

## 构建与运行

```powershell
flutter pub get
flutter run -d windows
```

仓库自带 [Makefile](Makefile) 作为常用任务的快捷方式(配方只用最普通的命令行,cmd.exe 和 sh 都能跑):

| 命令 | 作用 |
| --- | --- |
| `make` | 列出所有目标(默认目标) |
| `make run` | 从源码调试运行(`flutter run -d windows`) |
| `make release` / `make debug` | 只构建 Release / Debug |
| `make test` | 跑全部测试 |
| `make analyze` | 静态检查 |
| `make package` | 构建 Release 并产出安装包 |
| `make clean` / `make distclean` | 清理构建产物 / 连 `dist\` 和打包暂存一起清 |

不用 make 时,底层脚本是 [`tool\package_windows.ps1`](tool/package_windows.ps1)
(参数 `-SkipBuild` / `-Version`)。Windows 下 `make.cmd` 会把你转发给 make,前提是
`make` 在 `PATH` 里。

## 打包 Windows 安装包

```powershell
make package
```

产出 `dist\XGameDesktop-Setup-<版本>.exe`,版本号取自 `pubspec.yaml`。
`make package SKIPBUILD=1` 复用已有 Release 产物,`make package VERSION=1.2.0` 覆盖版本号。

安装包行为(见 [XGameDesktop.nsi](tool/installer/XGameDesktop.nsi)):

- **每用户安装**,默认 `%LOCALAPPDATA%\Programs\XGameDesktop`,安装程序本身不需要管理员权限
  (`RequestExecutionLevel user`)。界面为简体中文。
- 程序本体默认以管理员身份运行(exe 链接选项声明 `requireAdministrator`),每次启动弹一次 UAC,
  兼作知情确认。
- 可选项:**桌面快捷方式**(默认勾选)、**开机自启动**(默认不勾)。因为提权程序不能走 Run 键自启动,
  自启动改用计划任务 `XGameDesktop`(`/sc onlogon /rl highest`),勾选时需要一次管理员确认。
- **硬件监控驱动 (PawnIO)** 默认随包安装:包内自带官方签名安装器,以 `-install -silent` 静默安装,
  已装过的机器自动跳过(读 `HKLM\SYSTEM\CurrentControlSet\Services\PawnIO` 的 `ImagePath` 判断)。
  不装也能用,只是温度/功耗/风扇没有读数,应用内监控面板还可以再装。
- 机器缺 VC++ 运行库时自动运行 `vc_redist.x64.exe`(Release 用动态 CRT,缺库连窗口都开不出来)。
- 卸载会问是否一并删除用户数据,默认保留;**PawnIO 驱动有意不卸载**(系统级共享驱动,别的工具也在用)。
- 安装包没有代码签名,首次运行会弹 SmartScreen("仍要运行"即可)。

打包脚本会做两件容易被忽略的检查:重新按内容哈希同步 Release 目录里的 `hwprobe.dll`
(增量构建会跳过 CMake 的 install 步骤,否则可能打进旧 DLL),以及校验
[`MaterialIcons-Regular.otf` 图标字体](tool/check_icon_font.ps1) ——
`--tree-shake-icons` 属于资源复制步骤,增量构建被跳过时会留下**新 `app.so` + 旧图标字体**,
表现为图标全部空白且没有任何报错。

## 手柄按键映射

XInput 没有回调,所以手柄是轮询的:窗口在前台且有手柄时 16ms 一次,否则 250ms 一次
(热插拔和"窗口回到前台"仍然可用,又不白烧帧)。窗口不在前台时**完全不动** ——
系统会把键盘路由给焦点窗口,但没有任何机制把"手柄"路由出去,所以前台是游戏时按键属于游戏。

| 按键 | 动作 |
| --- | --- |
| A | 确认 / 启动聚焦的卡片 |
| B | 返回(关键盘、关菜单、退页面);**有意不退出沉浸模式** |
| X | 回到应用网格 |
| Y | 搜索(打开软键盘) |
| View | 切换沉浸模式(从 B 挪过来的:误触面键太容易) |
| Start | 聚焦卡片上开右键菜单,否则进设置页 |
| LB / RB | 切换 推荐 / 游戏 / 桌面 视图 |
| LT / RT | 聚焦滚动区翻页 |
| D-pad / 左摇杆 | 焦点移动(死区 7849/32767,方向带滞回,长按 380ms 后 90ms 重复) |

## 硬件监控后端

遥测数据来自独立的 Rust 项目 **[hwprobe](https://github.com/xgd16/hwprobe)** ——
它编译出 `hwprobe.dll`,提供 C ABI(本应用对应 **ABI 4**),覆盖
CPU / 内存 / GPU / 硬盘 / 网卡 / 电池 / 主板 / 显示器 / 惯性传感器 九类。

本应用只使用其中一部分能力(pull 模式):

- 调用 `hwprobe_init` / `hwprobe_shutdown` / `hwprobe_abi_version`、
  `hwprobe_get_category_count` / `_get_category_info` / `_get_device_count` / `_get_device_info` /
  `_get_sensor_count` / `_get_sensor_info`、`hwprobe_read_sensor`、`hwprobe_set_usage_mode`、
  `hwprobe_setup_driver`。
- **不使用订阅推送**(`hwprobe_subscribe`):它给出的批次指针只在原生调用期间有效,
  `NativeCallable.listener` 无法满足这个生命周期约束,所以这里用轮询。
- 风扇是**按单位 `rpm` 动态发现**的,因此 hwprobe 增加风扇不需要改动 ABI。

### 把 DLL 放到位

`hwprobe.dll` 不在本仓库中(tag 与源码都在 hwprobe 项目里)。二选一:

```powershell
# 方式一:从 hwprobe 构建(推荐)
git clone https://github.com/xgd16/hwprobe.git
cd hwprobe
cargo build --release
Copy-Item target\release\hwprobe.dll <本仓库>\native\hwprobe.dll

# 方式二:从 hwprobe 的 Release 下载,解压到 native\hwprobe.dll
```

`windows/CMakeLists.txt` 会把 `native\hwprobe.dll` 安装到构建出的 exe 旁边,
所以构建产物和安装包里都会有它。应用本身从不写或替换这个 DLL。

### 没有 DLL / 没有驱动时

这是有意设计的降级,不是崩溃路径:

| 情况 | 表现 |
| --- | --- |
| DLL 缺失或加载失败 | 遥测栏显示"监控后端未加载"与**重试**按钮,应用其余功能完全正常 |
| ABI 版本不匹配 | 同上,提示"ABI 版本不匹配 (得到 X,需要 4)" |
| DLL 在但初始化失败 | 提示具体原因(如"等待传感器数据超时") |
| 缺 PawnIO 驱动 | 温度/功耗/风扇空白,提示"温度、功耗与风扇读数需要硬件驱动" + **安装驱动**按钮 |
| 驱动已装但未提权 | 提示"需要以管理员身份运行" + **管理员重启**按钮 |

没有遥测数据时历史记录**不会**写入空行,所以曲线里不会出现虚假的洞。

### 采样口径

设置页可切换 hwprobe 的占用率口径,热切换、下一次刷新(≤1s)生效:

- **标准**(0,默认):CPU = 忙碌墙钟时间占比,GPU = 厂商 API(NVML/ADLX/IGCL)。
- **任务管理器**(1):CPU = PDH `% Processor Utility` ÷ `% Processor Performance`,
  GPU = GPU Engine 引擎计数器按类型聚合取最忙值。

## 动态壁纸系统

四类背景,由 [`AppBackground`](lib/ui/background_layer.dart) 分派:

| 类型 | 说明 | 实现 |
| --- | --- | --- |
| **图片** | 复制到数据目录(`background<毫秒>.<扩展名>`,保留扩展名给解码器),原文件可以随意移动/删除。支持填充/适应/平铺、0–0.9 暗化、0–24px 模糊 | [background_layer.dart](lib/ui/background_layer.dart) |
| **视频** | `media_kit`/libmpv,**按路径共享会话**(窗口背景与设置页预览共用一个解码器,引用计数),循环、静音、无控件,原地引用不复制 | [video_sessions.dart](lib/state/video_sessions.dart)、[video_background.dart](lib/ui/video_background.dart) |
| **网页** | 作者的 `index.html` 跑在 WebView2 里,经本地回环服务器提供,透明背景、禁缩放、禁右键、禁调试、`IgnorePointer` 让上层界面接管鼠标 | [web_background.dart](lib/ui/web_background.dart) |
| **场景** | 场景包由内置 WebGL2 渲染器绘制;作者的预览图垫在浏览器**下面**,所以几十 MB 的包在下载/编译期间显示的是预览图而不是白屏 —— WebGL2 不可用时它也仍然是一张图 | [scene_background.dart](lib/ui/scene_background.dart)、[scene_pkg.dart](lib/native/scene_pkg.dart) |

内置渲染器是 [webwallgl](assets/webwallgl.min.mjs)(MIT,见
[webwallgl.LICENSE](assets/webwallgl.LICENSE)),帧率可选 15/30/60(低功耗档压到 15 但不改动你保存的选择)。

### 为什么要本地 HTTP 服务器

`file://` 页面的源是不透明的,浏览器会拒绝加载它自己的 module script、样式表和 `fetch` ——
一个打包好的 Vite/React/three.js 网页壁纸会直接黑屏。Wallpaper Engine 之所以能直接打开文件,
是因为它的浏览器关掉了 Web 安全策略。放在 `127.0.0.1` 后面,页面就有了真正的源,相对路径就是隔壁文件。

[WallpaperServer](lib/state/wallpaper_server.dart) 只监听回环地址的临时端口,并且只服务显式注册过的目录;
拒绝 `..`、盘符冒号和分隔符,解析后还必须仍在注册根之下。支持 HEAD 与单段字节范围
(场景包几十上百 MB,浏览器的媒体栈会 seek 过去)。绑定失败时返回 null,调用方自行降级
(场景退回静态图,网页退回 `file://`)。

### Wallpaper Engine 集成

[wallpaper_engine.dart](lib/native/wallpaper_engine.dart) 是**只读、纯文件**的:不碰进程,
Wallpaper Engine 关着也能用,而且本应用从不依赖它。

- 安装位置:`HKCU\Software\WallpaperEngine` 的 `installPath`,再退回各 Steam 库的
  `steamapps\common\wallpaper_engine`。
- 壁纸目录:各库的 `steamapps\workshop\content\431960`,以及 `projects\myprojects`、`projects\defaultprojects`。
- 当前壁纸:解析 `<安装目录>\config.json`,不是标题 —— workshop 里标题会重复,所以身份是
  `项目目录|播放文件`(小写)。
- 采纳规则:视频原地播放、网页原地运行、`.pkg` 交给内置渲染器;**其余情况(或对应的原生能力不可用)
  解出一帧静态图**作为背景。

### 静态图降级

- **视频** → 通过系统缩略图提供者(`IShellItemImageFactory`)解出真实的一帧,并做墨迹覆盖率检查
  (`_minFrameInk = 0.9`)以拒绝通用文件图标 —— 图标画在透明方块上,覆盖率约 0.55–0.70,绝不会被
  误认为是一帧画面。缓存为 `we-frame-<哈希>.png`。
- **场景** → 从 `scene.pkg` 里**直接抽出作者的预览美术**
  ([extractSceneBackdrop](lib/native/scene_pkg.dart)):解析 `PKGV0006` 容器与
  `TEXV0005`/`TEXB000x` 纹理块,处理 LZ4 块解压,按文件名排除法线/遮罩/噪声等贴图,
  优先选 1.3–2.7 宽高比且 ≥1024px 的横图。格式参考社区工具 RePKG。
- 静态图缓存最多保留最新 8 个(`_pruneStills`)。

### 壁纸闸门

[WallpaperGate](lib/state/wallpaper_gate.dart) 把三个事实折叠成一个布尔值,决定动态壁纸是否运行:

1. **窗口不可见**(`AppActivity.visible`);
2. **被别的东西盖住**:每 2 秒一次 Win32 探测(前台全屏 **或** 前台窗口覆盖了本窗口) ——
   后者覆盖无边框游戏和"窗口化的启动器上盖着一个最大化的浏览器";
3. **被应用内部遮挡**:全屏页面打开时主动置位(设置页例外:它会用预览卡显示视频壁纸)。

关闭时视频暂停、WebView 挂起(`IsVisible=false` + `TrySuspend`)、缓动遥测停摆。

## 架构

```
lib/
├── core/     展示语汇,不含应用状态:配色/字体/动效/时钟文本/品牌几何
│             (brand.dart 是纯 Dart,不 import Flutter,所以图标生成器能在普通 VM 上跑)
├── data/     只有 SQLite:app_database / config_store / app_activity_store /
│             metric_database / metric_store / sqlite_transaction
├── native/   所有 FFI 与系统调用:win32_api(手写绑定,无 package:win32)、
│             hwprobe_bindings + hwprobe_service、gamepad(XInput)、icon_extract、
│             shell_apps、steam_games、wallpaper_engine、scene_pkg、window_shell 等
├── net/      天气(两个 HTTP API,无第三方依赖)
├── state/    ChangeNotifier provider + 若干进程级通知器(可见性/电源/壁纸闸门/回环服务器)
└── ui/       纯控件,20 个文件;provider 只通过 context 读取
```

- **状态管理**:[app.dart](lib/app.dart) 注册六个 `ChangeNotifier`(设置、硬件服务、遥测、
  应用库、天气、手柄)。`MaterialApp` 只订阅 `Selector<SettingsProvider, PaletteId>`,
  所以拖动模糊滑杆不会重建整个主题。
- **热路径用 `context.select` 而不是 `watch`**:整个遥测栏只订阅自己的读数,
  每个区块各自 `RepaintBoundary`。
- **测试缝隙靠构造注入,不靠全局变量**:`AppsProvider({dataDir, launcher, scanner})`、
  `SettingsProvider({dataDir})`、`MetricsProvider({dataDir, clock})`、
  `WeatherProvider({fetch, tick})`、`GamepadService({sampler, foreground, ...})`,
  以及 `WallpaperGate.probeOverride`、`WallpaperServer.assetsDirOverride` 等静态覆盖点。
- **原生层全是手写 `dart:ffi`**:没有 FFI 代码生成,Win32 调用不依赖 `package:win32`。
  `win32_api.dart` 自己打开 `kernel32/user32/gdi32/shell32/advapi32/ole32/comdlg32`。
  重活丢到 isolate:`Isolate.run(ShellApps.scan)` 与 `Isolate.run(SteamGames.scan)` 并发执行,
  图标提取用一个常驻 isolate 流式回传(约 100ms 一批),视频取帧与场景美术抽取各用一个 `Isolate.run`。
  runner 通过环境变量把窗口句柄交给 Dart(`XGAME_HWND`)。

### 存储

两个独立数据库,均为 WAL、`synchronous=NORMAL`、`busy_timeout=3000`、`PRAGMA user_version` 版本化、
表均为 `STRICT`:

- **`xgame.db`**(version 2):`config`(每个设置一行,`value_type ∈ {json,string,int,double,bool,enum}`,
  **枚举按名字存而不是下标**,避免重排 Dart 枚举把已存设置指错;缺行 = 从未设置,与"显式 0/false"区分开)、
  `app_usage`、`app_pin`、`app_meta`。
- **`metrics.db`**(version 1):`metric_sample`,17 个字段一次性枚举在 `MetricField` 里。
  刻意独立成库独立连接:一周的采样不该长期占住配置库的写锁,而且删掉它只损失读数。
  读取在 **SQL 里分桶**(`(ts/?)*?` + `avg()`),所以历史页一次扫描就能喂满 11 张图表。

## 数据目录与注册表

用户数据全部在 `%LOCALAPPDATA%\XGameDesktop`(设置页"关于"里显示该路径,并可一键打开):

| 文件/目录 | 内容 |
| --- | --- |
| `xgame.db` | 设置、启动次数、固定、导入标记 |
| `metrics.db` | 7 天设备历史,**可安全删除** |
| `icons\` | 提取的应用图标(可重新生成) |
| `games\` | Steam 封面缓存 |
| `background<毫秒>.<扩展名>` | 复制的静态壁纸(每次采纳会删掉旧的) |
| `we-frame-*.png` / `we-scene-*.jpg` | 静态图缓存(最多 8 个) |
| `settings.json` / `usage.json` / `pins.json` | 迁移前的旧文件,**只读一次、从不改写或删除**,留作回退路径 |

注册表:所有写操作都发生在**安装程序**里,应用本身只读(`lib/` 里没有任何注册表写入)。

- 应用**读取**:`HKCU\Software\WallpaperEngine\installPath`、
  `HKCU\Software\Valve\Steam\SteamPath`、`HKLM\SOFTWARE\Valve\Steam\InstallPath`(含 32 位视图)、
  `HKCU\...\Themes\Personalize\AppsUseLightTheme`(由 C++ runner 读取)。
- 安装程序**写入**:`HKCU\Software\XGameDesktop\InstallDir` 与
  `HKCU\...\Uninstall\XGameDesktop` 的卸载信息;并**删除**旧的
  `HKCU\...\Run\XGameDesktop`(改用计划任务)。
- 计划任务:名为 `XGameDesktop`,`/sc onlogon /rl highest`。

### 配置迁移

从 SQLite 之前的版本升级时:`xgame.db` 的 `user_version` 走 `0 → 1 → 2`;
`legacy.settings_json` 与 `legacy.app_activity` 记录在 `app_meta` 里,是单向的 ——
标记只在导入函数返回**之后**才写,且导入器写的是绝对值,所以中途中断下次启动会干净重试,
也不会重复计数。旧的 `settings.json` 里 `palette`/`fit` 原本存的是枚举**下标**,现在按**名字**读取;
无法识别或类型不符的值直接跳过并回退默认值。

## 测试

```powershell
make test        # 等价于 flutter test
```

**32 个测试文件、269 个用例**,覆盖 SQLite schema/类型/迁移/旧数据导入、遥测记录器的间隔钳制与
可见性闸门与 7 天清理、监控页各档范围与确认流程、壁纸闸门、回环服务器的路由/类型/目录穿越防护/
WE 材质端点、Wallpaper Engine 发现与工程解析与静态图解析、场景包解析 + LZ4 + 美术抽取、
Steam ACF 解析与封面选择、开始菜单扫描/分类/固定/排序/搜索、设置持久化、
手柄轮询语义(边沿触发、重复间隔、死区、热插拔、前台闸门)与手柄导航/焦点自愈、
以及品牌几何与 PNG 编码。

两点如实说明:测试套件里有**一个用例真的去碰宿主机的 XInput**
(`test/gamepad_test.dart`,`if (!Platform.isWindows) return;` 之后直接读手柄),
`test/wallpaper_server_test.dart` 会**真的绑定一个回环套接字**。
`LiveSurfaces.*` 默认为 false,所以没有测试会拉起 libmpv 或 WebView2;也没有测试需要 `hwprobe.dll`。

从命令行跑单个文件:

```powershell
flutter test test/gamepad_test.dart
```

## 已知限制

- **仅 Windows**。`win32_api.dart` 在 import 时直接打开七个 Windows DLL,手柄是 XInput,
  runner 是 C++/Win32;仓库里也只有 `windows/` 一个平台目录。
- **需要管理员权限**。程序作为桌面外壳运行并读取硬件遥测,所以每次启动都过一次 UAC。
- **界面只有简体中文且硬编码**,没有接入 `intl`/`flutter_localizations`。
- **遥测栏对屏幕阅读器不可见**。1Hz 重建的 HUD 会触发引擎的无障碍缺陷
  (`accessibility_bridge.cc "Nodes left pending"`),所以整栏被 `ExcludeSemantics` 包起来了。
  代码里的理由是"HUD 对屏幕阅读器没有用途",但这是个真实的限制。
- **场景壁纸需要 WebGL2**(WebView2 提供);视频壁纸需要 libmpv(media_kit);网页壁纸需要 WebView2。
  缺任何一个都会降级成静态图,而不是不可用。
- **窗口有硬性最小尺寸 1180×760**(逻辑像素),低于它布局会坏。
- **安装包和主程序都没有代码签名**,首次运行会弹 SmartScreen。
  (包内附带的 PawnIO 安装器**是**有签名的。)
- **任务栏融合状态会在进程异常退出时残留** —— 那个透明任务栏属性会一直留到有东西重写它或
  Explorer 重启。正常退出路径会先关掉 immersive 来规避。
- **依赖 `LOCALAPPDATA` 环境变量**:未设置时会静默写到临时目录。
- 如果你把 `tool\` 下的便携工具链删掉(本仓库默认不提交它们),`make package` 就会需要
  自备 GNU make 与 NSIS。

## 第三方组件与许可

本项目以 **MIT** 许可发布,见 [LICENSE](LICENSE)。随附的第三方组件:

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [webwallgl](assets/webwallgl.min.mjs) | 场景壁纸的 WebGL2 渲染器 | MIT,见 [webwallgl.LICENSE](assets/webwallgl.LICENSE) |
| [Rajdhani](assets/fonts/) | 遥测数字与字标字体 | SIL Open Font License 1.1 |
| [PawnIO](https://github.com/namazso/PawnIO) | 内核驱动(温度/功耗/风扇) | GPL-2.0,**附例外**:经设备 IOCTL 通信的独立软件不受感染 |
| [hwprobe](https://github.com/xgd16/hwprobe) | 硬件遥测 (DLL) | MIT |
| Flutter / Dart 依赖 | 见 `pubspec.yaml` | 各自的许可,`flutter build` 会把 `NOTICES.Z` 打进产物 |

PawnIO 安装器是本仓库**不提交**的二进制,取得方式与哈希校验见
[tool/installer/PawnIO_setup.README](tool/installer/PawnIO_setup.README)。

## 参与贡献

欢迎 Issue 与 PR。提交前请:

```powershell
make analyze     # 静态检查
make test        # 269 个用例应当全绿
```

- 新增设置项请加在 [settings_spec.dart](lib/state/settings_spec.dart) 的目录里 ——
  加载、保存与旧配置导入都从那一份目录读取,键和类型只在那里写一次。
- 需要触碰系统的地方请沿用现有的测试缝隙风格(构造注入或静态覆盖点),而不是加全局变量。
- 提交信息用中文或英文都可以。

---

如果这个项目对你有用,欢迎 Star ⭐ 或者提一个截图 PR。
