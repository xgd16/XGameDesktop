import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// Minimal hand-rolled Win32 bindings (user32 / gdi32 / shell32 / kernel32 /
// ole32 / comdlg32). Only the small stable surface this app needs — no package
// dependency.

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _user32 = DynamicLibrary.open('user32.dll');
final _gdi32 = DynamicLibrary.open('gdi32.dll');
final _shell32 = DynamicLibrary.open('shell32.dll');
final _advapi32 = DynamicLibrary.open('advapi32.dll');
final _ole32 = DynamicLibrary.open('ole32.dll');
final _comdlg32 = DynamicLibrary.open('comdlg32.dll');

// ---- constants ----
const gaRoot = 2;
const wmClose = 0x0010;
const wmNcLButtonDown = 0x00A1;
const wmSysCommand = 0x0112;
const scMinimize = 0xF020;
const htCaption = 0x0002;
const swMinimize = 6;
const swMaximize = 3;
const swRestore = 9;
const swShowNormal = 1;

const shgfiIcon = 0x000000100;
const shgfiLargeIcon = 0x000000000;
const fileAttributeNormal = 0x00000080;

// ---- kernel32 ----
final getCurrentProcessId =
    _kernel32.lookupFunction<Uint32 Function(), int Function()>(
        'GetCurrentProcessId');

// ---- kernel32: volume usage ----
final _getLogicalDriveStringsW = _kernel32.lookupFunction<
    Uint32 Function(Uint32, Pointer<Uint16>),
    int Function(int, Pointer<Uint16>)>('GetLogicalDriveStringsW');
final _getDriveTypeW = _kernel32
    .lookupFunction<Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)>('GetDriveTypeW');
final _getVolumeInformationW = _kernel32.lookupFunction<
    Int32 Function(
        Pointer<Utf16>,
        Pointer<Uint16>,
        Uint32,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint32>,
        Pointer<Uint16>,
        Uint32),
    int Function(Pointer<Utf16>, Pointer<Uint16>, int, Pointer<Uint32>,
        Pointer<Uint32>, Pointer<Uint32>, Pointer<Uint16>, int)>(
    'GetVolumeInformationW');
final _getDiskFreeSpaceExW = _kernel32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>,
        Pointer<Uint64>),
    int Function(
        Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>)>(
    'GetDiskFreeSpaceExW');

const driveTypeFixed = 3; // DRIVE_FIXED
const driveTypeRemovable = 2;

final _getSystemFirmwareTable = _kernel32.lookupFunction<
    Uint32 Function(Uint32, Uint32, Pointer, Uint32),
    int Function(int, int, Pointer, int)>('GetSystemFirmwareTable');

int getLogicalDriveStrings(int maxLen, Pointer<Uint16> buf) =>
    _getLogicalDriveStringsW(maxLen, buf);

int getDriveType(String path) {
  final p = path.toNativeUtf16();
  try {
    return _getDriveTypeW(p);
  } finally {
    calloc.free(p);
  }
}

({String label, bool ok}) getVolumeInformation(String path) {
  final p = path.toNativeUtf16();
  final nameBuf = calloc<Uint16>(261);
  final fsBuf = calloc<Uint16>(261);
  final serial = calloc<Uint32>();
  final maxLen = calloc<Uint32>();
  final flags = calloc<Uint32>();
  try {
    final ok = _getVolumeInformationW(p, nameBuf, 261, serial, maxLen, flags,
        fsBuf, 261);
    if (ok == 0) return (label: '', ok: false);
    var len = 0;
    while (len < 261 && nameBuf[len] != 0) {
      len++;
    }
    return (label: String.fromCharCodes(nameBuf.asTypedList(len)), ok: true);
  } finally {
    calloc.free(p);
    calloc.free(nameBuf);
    calloc.free(fsBuf);
    calloc.free(serial);
    calloc.free(maxLen);
    calloc.free(flags);
  }
}

({int total, int free})? getDiskFreeSpace(String path) {
  final p = path.toNativeUtf16();
  final total = calloc<Uint64>();
  final free = calloc<Uint64>();
  try {
    final ok = _getDiskFreeSpaceExW(p, nullptr, total, free);
    if (ok == 0 || total.value == 0) return null;
    return (total: total.value, free: free.value);
  } finally {
    calloc.free(p);
    calloc.free(total);
    calloc.free(free);
  }
}

/// Reads a raw firmware table (provider 'RSMB' = 0x52534D42 for SMBIOS).
int getSystemFirmwareTable(int provider, int tableId, Pointer buffer, int size) =>
    _getSystemFirmwareTable(provider, tableId, buffer, size);

// ---- shell32: file info + launching ----

final class ShFileInfoW extends Struct {
  @IntPtr()
  external int hIcon;
  @Int32()
  external int iIcon;
  @Uint32()
  external int dwAttributes;
  @Array(260)
  external Array<Uint16> szDisplayName;
  @Array(80)
  external Array<Uint16> szTypeName;
}

final _shGetFileInfoW = _shell32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Uint32, Pointer<ShFileInfoW>, Uint32,
        Uint32),
    int Function(Pointer<Utf16>, int, Pointer<ShFileInfoW>, int,
        int)>('SHGetFileInfoW');

final _shellExecuteW = _shell32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, Int32),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
        Pointer<Utf16>, int)>('ShellExecuteW');

/// Resolves the shell icon index for a path (follows .lnk shortcuts).
/// Returns (hIcon, iconIndex) — hIcon must be destroyed by the caller.
(int hIcon, int iIcon)? shGetFileIcon(String path) {
  final pathPtr = path.toNativeUtf16();
  final shfi = calloc<ShFileInfoW>();
  try {
    final rc = _shGetFileInfoW(
        pathPtr, fileAttributeNormal, shfi, sizeOf<ShFileInfoW>(), shgfiIcon);
    if (rc == 0 || shfi.ref.hIcon == 0) return null;
    return (shfi.ref.hIcon, shfi.ref.iIcon);
  } finally {
    calloc.free(pathPtr);
    calloc.free(shfi);
  }
}

// ---- shell32: desktop folders ----

final _shGetFolderPathW = _shell32.lookupFunction<
    Int32 Function(IntPtr, Int32, IntPtr, Uint32, Pointer<Utf16>),
    int Function(int, int, int, int, Pointer<Utf16>)>('SHGetFolderPathW');

const _csidlDesktopDirectory = 0x0010;
const _csidlCommonDesktopDirectory = 0x0019;

/// The current user's Desktop folder. Going through the shell rather than
/// `%USERPROFILE%\Desktop` keeps working when the folder is redirected to
/// OneDrive or renamed by a localized Windows.
String? userDesktopPath() => _folderPath(_csidlDesktopDirectory);

/// The all-users Desktop folder — shortcuts installers drop for everyone.
String? publicDesktopPath() => _folderPath(_csidlCommonDesktopDirectory);

String? _folderPath(int csidl) {
  final buf = calloc<Uint16>(260);
  try {
    if (_shGetFolderPathW(0, csidl, 0, 0, buf.cast<Utf16>()) != 0) return null;
    var len = 0;
    while (len < 260 && buf[len] != 0) {
      len++;
    }
    if (len == 0) return null;
    return String.fromCharCodes(buf.asTypedList(len));
  } finally {
    calloc.free(buf);
  }
}

/// Launches a file or shortcut. Returns true when handed to the shell.
///
/// [parameters] is the target's own command line, passed through untouched.
/// Use it for programs that parse that line themselves — Dart re-quotes every
/// `Process.start` argument, which turns the `/select,"C:\…"` Explorer wants
/// into `/select,\"C:\…\"`, and Explorer reads those escapes as part of the
/// path.
bool shellExecuteOpen(String path, {String? parameters}) {
  final pathPtr = path.toNativeUtf16();
  final opPtr = 'open'.toNativeUtf16();
  final paramsPtr = parameters?.toNativeUtf16() ?? nullptr;
  try {
    final h = _shellExecuteW(0, opPtr, pathPtr, paramsPtr, nullptr, 1);
    return h > 32;
  } finally {
    calloc.free(pathPtr);
    calloc.free(opPtr);
    if (paramsPtr != nullptr) calloc.free(paramsPtr);
  }
}

/// Launches [path] elevated (UAC prompt). Returns true on success.
bool shellExecuteRunAs(String path) {
  final pathPtr = path.toNativeUtf16();
  final verbPtr = 'runas'.toNativeUtf16();
  try {
    final h = _shellExecuteW(0, verbPtr, pathPtr, nullptr, nullptr, 1);
    return h > 32;
  } finally {
    calloc.free(pathPtr);
    calloc.free(verbPtr);
  }
}

// ---- advapi32: service status (non-admin queries are allowed) ----

const scManagerConnect = 0x0001;
const serviceQueryStatus = 0x0004;
const serviceRunning = 4;

final class ServiceStatus extends Struct {
  @Uint32()
  external int dwServiceType;
  @Uint32()
  external int dwCurrentState;
  @Uint32()
  external int dwControlsAccepted;
  @Uint32()
  external int dwWin32ExitCode;
  @Uint32()
  external int dwServiceSpecificExitCode;
  @Uint32()
  external int dwCheckPoint;
  @Uint32()
  external int dwWaitHint;
}

final _openSCManagerW = _advapi32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
    int Function(Pointer<Utf16>, Pointer<Utf16>, int)>('OpenSCManagerW');
final _openServiceW = _advapi32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Utf16>, Uint32),
    int Function(int, Pointer<Utf16>, int)>('OpenServiceW');
final _queryServiceStatus = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<ServiceStatus>),
    int Function(int, Pointer<ServiceStatus>)>('QueryServiceStatus');
final _closeServiceHandle = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'CloseServiceHandle');

/// True when the named Windows service exists and is running.
bool isServiceRunning(String name) {
  final scm = _openSCManagerW(nullptr, nullptr, scManagerConnect);
  if (scm == 0) return false;
  final namePtr = name.toNativeUtf16();
  final svc = _openServiceW(scm, namePtr, serviceQueryStatus);
  calloc.free(namePtr);
  if (svc == 0) {
    _closeServiceHandle(scm);
    return false;
  }
  final status = calloc<ServiceStatus>();
  final ok = _queryServiceStatus(svc, status) != 0 &&
      status.ref.dwCurrentState == serviceRunning;
  calloc.free(status);
  _closeServiceHandle(svc);
  _closeServiceHandle(scm);
  return ok;
}

// ---- user32: window plumbing ----
typedef _EnumWindowsCbC = Int32 Function(IntPtr hwnd, IntPtr lParam);
typedef EnumWindowsCbDart = int Function(int hwnd, int lParam);

final _enumWindows = _user32.lookupFunction<
    Int32 Function(Pointer<NativeFunction<_EnumWindowsCbC>>, IntPtr),
    int Function(
        Pointer<NativeFunction<_EnumWindowsCbC>>, int)>('EnumWindows');
final _getWindowThreadProcessId = _user32.lookupFunction<
    Uint32 Function(IntPtr, Pointer<Uint32>),
    int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
final _isWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible');
final _getAncestor = _user32.lookupFunction<IntPtr Function(IntPtr, Uint32),
    int Function(int, int)>('GetAncestor');
final _releaseCapture = _user32
    .lookupFunction<Int32 Function(), int Function()>('ReleaseCapture');
final _sendMessageW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('SendMessageW');
final _postMessageW = _user32.lookupFunction<
    Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
    int Function(int, int, int, int)>('PostMessageW');
final _showWindowAsync = _user32.lookupFunction<
    Int32 Function(IntPtr, Int32), int Function(int, int)>(
    'ShowWindowAsync');
final _isZoomed = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
final _getForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');

int findAppWindow() {
  final pid = getCurrentProcessId();
  int? found;
  final cb = NativeCallable<_EnumWindowsCbC>.isolateLocal((int hwnd, int lParam) {
    if (found != null) return 0;
    if (_isWindowVisible(hwnd) == 0) return 1;
    if (_getAncestor(hwnd, gaRoot) != hwnd) return 1;
    final windowPid = calloc<Uint32>();
    _getWindowThreadProcessId(hwnd, windowPid);
    final matches = windowPid.value == pid;
    calloc.free(windowPid);
    if (matches) found = hwnd;
    return found != null ? 0 : 1;
  }, exceptionalReturn: 0);
  try {
    _enumWindows(cb.nativeFunction, 0);
  } finally {
    cb.close();
  }
  return found ?? 0;
}

void beginCaptionDrag(int hwnd) {
  _releaseCapture();
  _sendMessageW(hwnd, wmNcLButtonDown, htCaption, 0);
}

/// The shell's own fullscreen windows: the desktop is Progman (with WorkerW
/// feeding it a wallpaper layer), and the taskbars fill their monitors when
/// auto-hidden. They cover the screen, but they are not apps gone fullscreen.
const _shellFullscreenClasses = ['Progman', 'WorkerW'];

/// Whether the foreground window is an app fullscreen over its whole monitor —
/// exclusive or borderless, the rect check covers both. This is the Wallpaper
/// Engine pause rule: such a window hides everything under it, so live
/// wallpapers would be rendering for nobody. The shell windows above and this
/// app's own immersive ([selfHwnd]) never count.
bool foregroundFullscreen(int selfHwnd) {
  final fg = _getForegroundWindow();
  if (fg == 0 || fg == selfHwnd) return false;
  for (final name in _shellFullscreenClasses) {
    if (_classNameIs(fg, name)) return false;
  }
  final rect = calloc<WinRect>();
  final info = calloc<MonitorInfo>();
  try {
    if (_getWindowRect(fg, rect) == 0) return false;
    final monitor = _monitorFromWindow(fg, _monitorDefaultToNearest);
    info.ref.cbSize = sizeOf<MonitorInfo>();
    if (monitor == 0 || _getMonitorInfoW(monitor, info) == 0) return false;
    final m = info.ref.rcMonitor;
    final r = rect.ref;
    return r.left <= m.left &&
        r.top <= m.top &&
        r.right >= m.right &&
        r.bottom >= m.bottom;
  } finally {
    calloc.free(rect);
    calloc.free(info);
  }
}

/// Whether the foreground window hides this app's own window.
///
/// The other half of the same rule [foregroundFullscreen] answers. That one
/// covers the classic case — a game exclusive or borderless over its whole
/// monitor; this one covers the case it misses: a borderless game that does not
/// fill the monitor, a maximized browser, anything that happens to sit over the
/// launcher while the launcher keeps rendering a wallpaper underneath it. Both
/// mean the same thing to a wallpaper: nobody can see it.
///
/// Windows of our own process never count. The Flutter view is a child of the
/// shell's window and it is the window with the focus most of the time, so
/// without that test the app would read as covered by itself.
bool foregroundCovers(int selfHwnd) {
  final fg = _getForegroundWindow();
  if (fg == 0 || fg == selfHwnd || _isOwnWindow(fg)) return false;
  for (final name in _shellFullscreenClasses) {
    if (_classNameIs(fg, name)) return false;
  }
  final fgRect = calloc<WinRect>();
  final selfRect = calloc<WinRect>();
  try {
    if (_getWindowRect(fg, fgRect) == 0) return false;
    if (_getWindowRect(selfHwnd, selfRect) == 0) return false;
    final f = fgRect.ref;
    final s = selfRect.ref;
    // A minimized window reports an empty or far-off-screen rect; it covers
    // nothing, whatever the arithmetic says.
    if (f.right <= f.left || f.bottom <= f.top) return false;
    return f.left <= s.left &&
        f.top <= s.top &&
        f.right >= s.right &&
        f.bottom >= s.bottom;
  } finally {
    calloc.free(fgRect);
    calloc.free(selfRect);
  }
}

/// Whether [hwnd] is a window of this process — the shell's own window, its
/// Flutter view, or a dialog it opened.
bool _isOwnWindow(int hwnd) {
  final pid = calloc<Uint32>();
  try {
    _getWindowThreadProcessId(hwnd, pid);
    return pid.value == getCurrentProcessId();
  } finally {
    calloc.free(pid);
  }
}

/// Whether this app owns the foreground window — its own top-level window, or
/// any window it owns, a native dialog say.
///
/// The keyboard never needs this test: Windows delivers its events to the
/// focused window and nowhere else. The pad does, because XInput is a global
/// poll — it reads whichever pad is plugged in whoever is in front — so this
/// is the only way to tell a press meant for us from one meant for the window
/// the user is actually working in (usually the game we just started).
///
/// Compares through the root window and the process id: the foreground window
/// may be a child of ours (the Flutter view), and a dialog is a window of
/// ours that is not [selfHwnd]. Fail-open when Windows reports no foreground
/// window at all — nothing claims the pad then, so it is ours.
bool appIsForeground(int selfHwnd) {
  final fg = _getForegroundWindow();
  if (fg == 0) return true;
  final root = _getAncestor(fg, gaRoot);
  if ((root == 0 ? fg : root) == selfHwnd) return true;
  return _isOwnWindow(fg);
}

// ---- user32: touch screen / manual window moves ----
//
// A finger cannot drive the caption-drag loop above: that loop is a modal
// DefWindowProc that waits for a mouse-up (or GetAsyncKeyState(VK_LBUTTON)),
// and a touch contact never sends either, so the window would stay stuck to
// the cursor until a real mouse clicked. Touch drags move the window by hand
// with SetWindowPos instead.

const _smDigitizer = 94;
const _smMaximumTouches = 95;
const _nidIntegratedTouch = 0x40;
const _nidExternalTouch = 0x80;

final _getSystemMetrics = _user32
    .lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
final _getWindowRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<WinRect>),
    int Function(int, Pointer<WinRect>)>('GetWindowRect');

/// Whether the machine has a touch digitizer at all. Pen-only tablets report
/// touches as 0 and are not treated as touch screens — the finger is what the
/// bigger hit targets and the soft keyboard exist for.
bool hasTouchScreen() {
  if (_getSystemMetrics(_smMaximumTouches) <= 0) return false;
  final flags = _getSystemMetrics(_smDigitizer);
  return flags & (_nidIntegratedTouch | _nidExternalTouch) != 0;
}

/// The window's rect in physical screen pixels, or null when [hwnd] is not a
/// window.
({int left, int top, int width, int height})? windowRect(int hwnd) {
  if (hwnd == 0) return null;
  final rect = calloc<WinRect>();
  try {
    if (_getWindowRect(hwnd, rect) == 0) return null;
    return (
      left: rect.ref.left,
      top: rect.ref.top,
      width: rect.ref.right - rect.ref.left,
      height: rect.ref.bottom - rect.ref.top,
    );
  } finally {
    calloc.free(rect);
  }
}

/// Moves [hwnd] to the physical screen position (x, y), size and z-order
/// untouched.
bool moveWindow(int hwnd, int x, int y) =>
    _setWindowPos(hwnd, 0, x, y, 0, 0,
        _swpNoSize | _swpNoZOrder | _swpNoActivate) !=
    0;

void minimizeWindow(int hwnd) => _showWindowAsync(hwnd, swMinimize);

void toggleMaximizeWindow(int hwnd) =>
    _showWindowAsync(hwnd, _isZoomed(hwnd) != 0 ? swRestore : swMaximize);

void closeWindow(int hwnd) => _postMessageW(hwnd, wmClose, 0, 0);

// ---- user32: immersive fullscreen ----
//
// Immersive mode swaps the window style for a plain popup — no frame, no
// caption. Where the window sits depends on [enterFullscreen]'s taskbarBlend:
// blended it plays the desktop all the way under the taskbar (which goes
// transparent, see the accent section below), otherwise it stops at the work
// area with the taskbar on its own background. The previous style and
// placement are kept so leaving the mode puts the window back exactly where
// it was — including a maximized state.

const _gwlStyle = -16;
const _wsPopup = 0x80000000;
const _wsVisible = 0x10000000;
const _wsClipChildren = 0x02000000;
const _wsClipSiblings = 0x04000000;

const _monitorDefaultToNearest = 2;

const _swpNoSize = 0x0001;
const _swpNoMove = 0x0002;
const _swpNoZOrder = 0x0004;
const _swpNoActivate = 0x0010;
const _swpFrameChanged = 0x0020;
const _swpShowWindow = 0x0040;

final class WinPoint extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class WinRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

/// WINDOWPLACEMENT — where the window sits when not fullscreen, plus the show
/// state (normal / maximized) it should return to.
final class WindowPlacement extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int flags;
  @Uint32()
  external int showCmd;
  external WinPoint ptMinPosition;
  external WinPoint ptMaxPosition;
  external WinRect rcNormalPosition;
}

final class MonitorInfo extends Struct {
  @Uint32()
  external int cbSize;
  external WinRect rcMonitor;
  external WinRect rcWork;
  @Uint32()
  external int dwFlags;
}

final _getWindowLongPtrW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32),
    int Function(int, int)>('GetWindowLongPtrW');
final _setWindowLongPtrW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32, IntPtr),
    int Function(int, int, int)>('SetWindowLongPtrW');
final _setWindowPos = _user32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
    int Function(int, int, int, int, int, int, int)>('SetWindowPos');
final _monitorFromWindow = _user32.lookupFunction<
    IntPtr Function(IntPtr, Uint32),
    int Function(int, int)>('MonitorFromWindow');
final _getMonitorInfoW = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<MonitorInfo>),
    int Function(int, Pointer<MonitorInfo>)>('GetMonitorInfoW');
final _getWindowPlacement = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<WindowPlacement>),
    int Function(int, Pointer<WindowPlacement>)>('GetWindowPlacement');
final _setWindowPlacement = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<WindowPlacement>),
    int Function(int, Pointer<WindowPlacement>)>('SetWindowPlacement');

int? _savedStyle;
Pointer<WindowPlacement>? _savedPlacement;
int _immersiveBottomInset = 0;

/// How many physical pixels along the window's bottom edge are covered by the
/// taskbar while a blended immersive is up — the band the app has to keep its
/// bottom-anchored controls out of. Zero whenever the window is framed, or
/// immersive stops above the bar on its own background.
int immersiveBottomInset() => _immersiveBottomInset;

/// Blows [hwnd] up to a borderless window on its monitor. With [taskbarBlend]
/// it covers the whole monitor minus the last pixel row at the bottom edge —
/// the shortfall keeps the shell from filing the window as full screen, so
/// the taskbar stays on top of it — and the taskbars over that monitor go
/// transparent, so the app's background shows through them; the leftover row
/// is painted over by a backdrop strip in [backdropColor] (see below).
/// Without the blend it stops at the work area and the taskbar keeps its own
/// background. The bar stays on top either way, so the blend also records how
/// tall it is (see [immersiveBottomInset]). Returns false (leaving the window
/// alone) when it cannot be done; true also when the window is already
/// immersive.
bool enterFullscreen(int hwnd, {bool taskbarBlend = false, int backdropColor = 0xFF000000}) {
  if (hwnd == 0) return false;
  if (_savedPlacement != null) return true;

  final placement = calloc<WindowPlacement>();
  placement.ref.length = sizeOf<WindowPlacement>();
  if (_getWindowPlacement(hwnd, placement) == 0) {
    calloc.free(placement);
    return false;
  }

  final monitor = _monitorFromWindow(hwnd, _monitorDefaultToNearest);
  final info = calloc<MonitorInfo>();
  info.ref.cbSize = sizeOf<MonitorInfo>();
  if (monitor == 0 || _getMonitorInfoW(monitor, info) == 0) {
    calloc.free(placement);
    calloc.free(info);
    return false;
  }
  final monitorRect = _copyRect(info.ref.rcMonitor);
  final workRect = _copyRect(info.ref.rcWork);
  calloc.free(info);

  // (An auto-hidden taskbar reports the full monitor as the work area; it
  // still reveals itself over the window when summoned.)
  var blended = taskbarBlend && _blendTaskbarsOver(monitorRect);
  var strip = 0;
  if (blended) {
    strip = _createBackdropStrip(monitorRect, backdropColor);
    if (strip == 0) {
      // Without the strip the last pixel row would show the wallpaper; the
      // blend degrades to the plain work-area immersive.
      _unblendTaskbars();
      blended = false;
    }
  }
  final rect = blended ? monitorRect : workRect;
  final width = rect.right - rect.left;
  final height = rect.bottom - rect.top - (blended ? 1 : 0);

  final style = _getWindowLongPtrW(hwnd, _gwlStyle);
  _setWindowLongPtrW(
      hwnd, _gwlStyle, _wsPopup | _wsVisible | _wsClipChildren | _wsClipSiblings);
  final ok = _setWindowPos(hwnd, 0, rect.left, rect.top, width, height,
          _swpFrameChanged | _swpShowWindow | _swpNoZOrder | _swpNoActivate) !=
      0;
  if (!ok) {
    _setWindowLongPtrW(hwnd, _gwlStyle, style);
    if (strip != 0) _destroyWindow(strip);
    _unblendTaskbars();
    calloc.free(placement);
    return false;
  }

  _stripHwnd = strip != 0 ? strip : null;
  _savedStyle = style;
  _savedPlacement = placement;
  _immersiveBottomInset = blended ? monitorRect.bottom - workRect.bottom : 0;
  return true;
}

/// Puts [hwnd] back the way it was before [enterFullscreen] and tears down
/// everything the blend put up — the backdrop strip and the taskbars'
/// transparency. False when the window was not immersive to begin with.
bool exitFullscreen(int hwnd) {
  final placement = _savedPlacement;
  final style = _savedStyle;
  if (hwnd == 0 || placement == null || style == null) return false;

  final strip = _stripHwnd;
  _stripHwnd = null;
  _immersiveBottomInset = 0;
  if (strip != null) _destroyWindow(strip);
  if (_stripBrush != null) {
    _deleteObject(_stripBrush!);
    _stripBrush = null;
  }
  _setWindowLongPtrW(hwnd, _gwlStyle, style);
  _setWindowPlacement(hwnd, placement);
  _setWindowPos(hwnd, 0, 0, 0, 0, 0,
      _swpFrameChanged | _swpNoMove | _swpNoSize | _swpNoZOrder | _swpNoActivate);
  _unblendTaskbars();

  calloc.free(placement);
  _savedPlacement = null;
  _savedStyle = null;
  return true;
}

// ---- user32: taskbar accent (immersive blend) ----
//
// The taskbar's background is one accent policy away:
// SetWindowCompositionAttribute (the undocumented but decade-stable channel
// TranslucentTB uses) rewrites it per taskbar window. Blending writes a fully
// transparent gradient onto every taskbar over the immersive monitor, so
// whatever the app paints at the bottom of its window becomes the taskbar's
// background; unblending writes ACCENT_DISABLED back to exactly the bars it
// touched, plus a composition-changed poke so Explorer re-renders.
//
// The attribute sticks until something rewrites it: if the process dies
// while blended, the taskbar stays clear until Explorer restarts (or the
// user toggles the setting, which unblends first).

const _accentDisabled = 0;
const _accentTransparentGradient = 2;

/// Bit 1 of AccentFlags goes with the gradient states; acrylic is the one
/// that wants it clear.
const _accentFlagGradient = 2;
const _wcaAccentPolicy = 11;
const _wmDwmCompositionChanged = 0x031E;

final class AccentPolicy extends Struct {
  @Int32()
  external int accentState;
  @Int32()
  external int accentFlags;
  @Uint32()
  external int gradientColor;
  @Int32()
  external int animationId;
}

final class WindowCompositionAttribData extends Struct {
  @Uint32()
  external int attrib;
  external Pointer<AccentPolicy> data;
  @UintPtr()
  external int dataSize;
}

final _findWindowW = _user32.lookupFunction<
    IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
    int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
final _getClassNameW = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint16>, Int32),
    int Function(int, Pointer<Uint16>, int)>('GetClassNameW');
final _setWindowCompositionAttribute = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<WindowCompositionAttribData>),
    int Function(int, Pointer<WindowCompositionAttribData>)>(
    'SetWindowCompositionAttribute');

({int left, int top, int right, int bottom}) _copyRect(WinRect r) =>
    (left: r.left, top: r.top, right: r.right, bottom: r.bottom);

bool _classNameIs(int hwnd, String expected) {
  final buf = calloc<Uint16>(64);
  try {
    final len = _getClassNameW(hwnd, buf, 64);
    if (len <= 0 || len >= 64) return false;
    return String.fromCharCodes(buf.asTypedList(len)) == expected;
  } finally {
    calloc.free(buf);
  }
}

/// The taskbar windows whose rect overlaps [area]: the primary bar plus one
/// secondary bar per further monitor.
List<int> _taskbarsOver(({int left, int top, int right, int bottom}) area) {
  void consider(int hwnd, List<int> bars) {
    final r = windowRect(hwnd);
    if (r == null) return;
    final overlaps = r.left < area.right &&
        r.left + r.width > area.left &&
        r.top < area.bottom &&
        r.top + r.height > area.top;
    if (overlaps) bars.add(hwnd);
  }

  final bars = <int>[];
  final primaryName = 'Shell_TrayWnd'.toNativeUtf16();
  final cb = NativeCallable<_EnumWindowsCbC>.isolateLocal((int hwnd, int lParam) {
    if (_classNameIs(hwnd, 'Shell_SecondaryTrayWnd')) consider(hwnd, bars);
    return 1;
  }, exceptionalReturn: 0);
  try {
    final primary = _findWindowW(primaryName, nullptr);
    if (primary != 0) consider(primary, bars);
    _enumWindows(cb.nativeFunction, 0);
  } finally {
    cb.close();
    calloc.free(primaryName);
  }
  return bars;
}

bool _applyAccent(int hwnd, int accentState, int gradientColor,
    {int accentFlags = _accentFlagGradient}) {
  final policy = calloc<AccentPolicy>();
  final data = calloc<WindowCompositionAttribData>();
  try {
    policy.ref
      ..accentState = accentState
      ..accentFlags = accentFlags
      ..gradientColor = gradientColor
      ..animationId = 0;
    data.ref
      ..attrib = _wcaAccentPolicy
      ..data = policy
      ..dataSize = sizeOf<AccentPolicy>();
    return _setWindowCompositionAttribute(hwnd, data) != 0;
  } finally {
    calloc.free(policy);
    calloc.free(data);
  }
}

List<int>? _blendedTaskbars;

/// Writes the transparent accent onto every taskbar over [area]. True when at
/// least one bar took it — the window only slides underneath when the bars
/// above it actually went clear.
bool _blendTaskbarsOver(({int left, int top, int right, int bottom}) area) {
  final bars = _taskbarsOver(area)
      .where((bar) => _applyAccent(bar, _accentTransparentGradient, 0))
      .toList();
  _blendedTaskbars = bars.isNotEmpty ? bars : null;
  return bars.isNotEmpty;
}

/// Puts every taskbar the blend touched back on its own background.
void _unblendTaskbars() {
  final bars = _blendedTaskbars;
  if (bars == null) return;
  _blendedTaskbars = null;
  for (final bar in bars) {
    _applyAccent(bar, _accentDisabled, 0, accentFlags: 0);
    _postMessageW(bar, _wmDwmCompositionChanged, 0, 0);
  }
}

// ---- user32/gdi32: the bottom backdrop strip ----
//
// Blended immersive keeps the window one pixel short of the monitor's bottom
// edge. The shortfall is load-bearing: a window whose rect covers every pixel
// of a monitor enters the shell's full screen set, and once such a window is
// the top one on that monitor the taskbar loses its always-on-top status and
// drops behind the app (the shell's "rude window manager"; mechanism
// reverse-engineered by dechamps/RudeWindowFixer — a helper window that is
// invisible and click-through does not change the verdict, the scan skips
// non-interactive windows). What the shortfall costs is one pixel row where
// the desktop wallpaper peeks through the transparent taskbar. The backdrop
// strip covers exactly that row: a one-pixel window painted in the app's own
// backdrop color, so the taskbar reads as part of the app all the way down.
// It sits in the normal Z-order — the taskbar, being topmost, stays above it
// — and lives and dies with the immersive mode.
//
// Its window procedure is DefWindowProcW itself, so no Dart code ever runs in
// its message path; the class background brush provides the color wherever
// DefWindowProc erases. Created on, and destroyed on, the platform thread,
// which every caller here already runs on.

const _stripClassName = 'XGameImmersiveBackdrop';
const _wsExToolWindow = 0x00000080;
const _wsExNoActivate = 0x08000000;
const _gclpHbrBackground = -10;

typedef WndProcC = IntPtr Function(
    IntPtr hwnd, Uint32 msg, IntPtr wParam, IntPtr lParam);

final class WndClassExW extends Struct {
  @Uint32()
  external int cbSize;
  @Uint32()
  external int style;
  external Pointer<NativeFunction<WndProcC>> wndProc;
  @Int32()
  external int cbClsExtra;
  @Int32()
  external int cbWndExtra;
  external Pointer<Void> hInstance;
  external Pointer<Void> hIcon;
  external Pointer<Void> hCursor;
  external Pointer<Void> hbrBackground;
  external Pointer<Utf16> lpszMenuName;
  external Pointer<Utf16> lpszClassName;
  external Pointer<Void> hIconSm;
}

final _defWindowProcW =
    _user32.lookup<NativeFunction<WndProcC>>('DefWindowProcW');
final _getModuleHandleW = _kernel32.lookupFunction<
    Pointer<Void> Function(Pointer<Utf16>),
    Pointer<Void> Function(Pointer<Utf16>)>('GetModuleHandleW');
final _registerClassExW = _user32.lookupFunction<
    Uint16 Function(Pointer<WndClassExW>),
    int Function(Pointer<WndClassExW>)>('RegisterClassExW');
final _createWindowExW = _user32.lookupFunction<
    IntPtr Function(
        Uint32,
        Pointer<Utf16>,
        Pointer<Utf16>,
        Uint32,
        Int32,
        Int32,
        Int32,
        Int32,
        IntPtr,
        IntPtr,
        Pointer<Void>,
        Pointer<Void>),
    int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, int, int, int, int,
        int, int, Pointer<Void>, Pointer<Void>)>('CreateWindowExW');
final _destroyWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyWindow');
final _setClassLongPtrW = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32, IntPtr),
    int Function(int, int, int)>('SetClassLongPtrW');
final _invalidateRect = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Void>, Int32),
    int Function(int, Pointer<Void>, int)>('InvalidateRect');
final _updateWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('UpdateWindow');
final _createSolidBrush = _gdi32.lookupFunction<Pointer<Void> Function(Uint32),
    Pointer<Void> Function(int)>('CreateSolidBrush');

bool _stripClassRegistered = false;
int? _stripHwnd;
int? _stripBrush;

void _ensureStripClass() {
  if (_stripClassRegistered) return;
  final name = _stripClassName.toNativeUtf16();
  final wc = calloc<WndClassExW>();
  try {
    wc.ref
      ..cbSize = sizeOf<WndClassExW>()
      ..wndProc = _defWindowProcW
      ..hInstance = _getModuleHandleW(nullptr)
      ..lpszClassName = name;
    _stripClassRegistered = _registerClassExW(wc) != 0;
  } finally {
    calloc.free(wc);
    calloc.free(name);
  }
}

/// Creates the strip covering the monitor's last pixel row, painted in
/// [backdropColor] (Dart ARGB). Zero when it could not be created — callers
/// then fall back to the work-area immersive, which leaves no gap to paint.
int _createBackdropStrip(
    ({int left, int top, int right, int bottom}) monitor, int backdropColor) {
  _ensureStripClass();
  if (!_stripClassRegistered) return 0;
  final className = _stripClassName.toNativeUtf16();
  try {
    final hwnd = _createWindowExW(
        _wsExToolWindow | _wsExNoActivate,
        className,
        nullptr,
        _wsPopup,
        monitor.left,
        monitor.bottom - 1,
        monitor.right - monitor.left,
        1,
        0,
        0,
        nullptr,
        nullptr);
    if (hwnd == 0) return 0;
    // Swap the class brush to the theme's backdrop color; the window paints
    // itself with it wherever DefWindowProc erases.
    final colorref = ((backdropColor & 0xFF) << 16) |
        (backdropColor & 0xFF00) |
        ((backdropColor >> 16) & 0xFF);
    final brush = _createSolidBrush(colorref);
    if (brush == nullptr) return 0;
    final old = _setClassLongPtrW(hwnd, _gclpHbrBackground, brush.address);
    if (old != 0) _deleteObject(old);
    _stripBrush = brush.address;
    _setWindowPos(hwnd, 0, 0, 0, 0, 0,
        _swpNoSize | _swpNoMove | _swpNoActivate | _swpShowWindow);
    // Erase and paint synchronously, so the row is never seen unpainted.
    _invalidateRect(hwnd, nullptr, 1);
    _updateWindow(hwnd);
    return hwnd;
  } finally {
    calloc.free(className);
  }
}

// ---- user32 / gdi32: icon extraction ----
final _privateExtractIconsW = _user32.lookupFunction<
    Uint32 Function(Pointer<Utf16>, Int32, Int32, Int32, Pointer<IntPtr>,
        Pointer<Uint32>, Int32, Uint32),
    int Function(Pointer<Utf16>, int, int, int, Pointer<IntPtr>,
        Pointer<Uint32>, int, int)>('PrivateExtractIconsW');
final _getIconInfo = _user32.lookupFunction<
    Int32 Function(IntPtr, Pointer<IconInfo>),
    int Function(int, Pointer<IconInfo>)>('GetIconInfo');
final _destroyIcon = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DestroyIcon');

void destroyIcon(int hicon) {
  if (hicon != 0) _destroyIcon(hicon);
}
final _createCompatibleDC = _gdi32
    .lookupFunction<IntPtr Function(IntPtr), int Function(int)>(
        'CreateCompatibleDC');
final _deleteDC = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
final _deleteObject = _gdi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
final _getDIBits = _gdi32.lookupFunction<
    Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer, Pointer<BitmapInfo>,
        Uint32),
    int Function(int, int, int, int, Pointer, Pointer<BitmapInfo>,
        int)>('GetDIBits');

/// Extracts a single icon from [path] at [size]×[size] px, or 0 on failure.
/// Handles .exe / .dll / .ico directly.
int extractIconHandle(String path, int size) {
  final pathPtr = path.toNativeUtf16();
  final hicon = calloc<IntPtr>();
  final iconId = calloc<Uint32>();
  try {
    final count = _privateExtractIconsW(
        pathPtr, 0, size, size, hicon, iconId, 1, 0);
    if (count >= 1 && hicon.value != 0) return hicon.value;
    return 0;
  } finally {
    calloc.free(pathPtr);
    calloc.free(hicon);
    calloc.free(iconId);
  }
}

final class IconInfo extends Struct {
  @Int32()
  external int fIcon;
  @Uint32()
  external int xHotspot;
  @Uint32()
  external int yHotspot;
  @IntPtr()
  external int hbmMask;
  @IntPtr()
  external int hbmColor;
}

final class BitmapInfoHeader extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

final class BitmapInfo extends Struct {
  external BitmapInfoHeader bmiHeader;
  // Palette entries follow the header; we only use BI_RGB 32bpp (no palette).
  @Array(2)
  external Array<Uint32> bmiColors;
}

/// Raw pixel data of an icon: top-down BGRA plus, for HICONs, the 1bpp
/// visibility mask. Shell bitmaps carry a real alpha channel instead and
/// leave [mask] null.
typedef IconPixels = ({
  int width,
  int height,
  Uint32List bgra,
  Uint8List? mask,
  int maskRowBytes,
});

/// Converts an HICON into raw top-down BGRA pixels plus dimensions.
/// Returns null when GDI gives up. Caller must destroy [hicon].
IconPixels? hiconToBgra(int hicon) {
  final info = calloc<IconInfo>();
  final ok = _getIconInfo(hicon, info);
  if (ok == 0) {
    calloc.free(info);
    return null;
  }
  final hbmColor = info.ref.hbmColor;
  final hbmMask = info.ref.hbmMask;
  calloc.free(info);

  final hdc = _createCompatibleDC(0);
  final bmi = calloc<BitmapInfo>();
  bmi.ref.bmiHeader.biSize = sizeOf<BitmapInfoHeader>();
  try {
    // Dimensions probe.
    if (_getDIBits(hdc, hbmColor, 0, 0, nullptr, bmi, 0) == 0) return null;
    final width = bmi.ref.bmiHeader.biWidth;
    final height = bmi.ref.bmiHeader.biHeight.abs();

    bmi.ref.bmiHeader.biBitCount = 32;
    bmi.ref.bmiHeader.biCompression = 0; // BI_RGB
    bmi.ref.bmiHeader.biHeight = -height; // top-down
    final pixelCount = width * height;
    final colorBuf = calloc<Uint32>(pixelCount);
    _getDIBits(hdc, hbmColor, 0, height, colorBuf, bmi, 0);
    final bgra = Uint32List(pixelCount)
      ..setRange(0, pixelCount, colorBuf.asTypedList(pixelCount));
    calloc.free(colorBuf);

    // 1bpp mask, rows padded to 32 bits.
    final maskRowBytes = ((width + 31) ~/ 32) * 4;
    final maskSize = maskRowBytes * height;
    final maskBuf = calloc<Uint8>(maskSize);
    final maskBmi = calloc<BitmapInfo>();
    maskBmi.ref.bmiHeader.biSize = sizeOf<BitmapInfoHeader>();
    maskBmi.ref.bmiHeader.biBitCount = 1;
    maskBmi.ref.bmiHeader.biCompression = 0; // BI_RGB
    maskBmi.ref.bmiHeader.biWidth = width;
    maskBmi.ref.bmiHeader.biHeight = -height;
    _getDIBits(hdc, hbmMask, 0, height, maskBuf, maskBmi, 0);
    calloc.free(maskBmi);
    final mask = Uint8List(maskSize)
      ..setRange(0, maskSize, maskBuf.asTypedList(maskSize));
    calloc.free(maskBuf);

    return (
      width: width,
      height: height,
      bgra: bgra,
      mask: mask,
      maskRowBytes: maskRowBytes,
    );
  } finally {
    _deleteObject(hbmColor);
    _deleteObject(hbmMask);
    _deleteDC(hdc);
    calloc.free(bmi);
  }
}

/// Releases a GDI object — the HBITMAP counterpart of [destroyIcon].
void deleteGdiObject(int handle) {
  if (handle != 0) _deleteObject(handle);
}

/// Raw top-down BGRA of an HBITMAP handed back by the shell. These are DIB
/// sections with a real (premultiplied) alpha channel, so there is no mask.
IconPixels? hBitmapToPixels(int hbmp) {
  final hdc = _createCompatibleDC(0);
  final bmi = calloc<BitmapInfo>();
  bmi.ref.bmiHeader.biSize = sizeOf<BitmapInfoHeader>();
  try {
    if (_getDIBits(hdc, hbmp, 0, 0, nullptr, bmi, 0) == 0) return null;
    final width = bmi.ref.bmiHeader.biWidth;
    final height = bmi.ref.bmiHeader.biHeight.abs();
    if (width <= 0 || height <= 0) return null;

    bmi.ref.bmiHeader.biBitCount = 32;
    bmi.ref.bmiHeader.biCompression = 0; // BI_RGB
    bmi.ref.bmiHeader.biHeight = -height; // top-down
    final pixelCount = width * height;
    final buf = calloc<Uint32>(pixelCount);
    try {
      if (_getDIBits(hdc, hbmp, 0, height, buf, bmi, 0) == 0) return null;
      return (
        width: width,
        height: height,
        bgra: Uint32List(pixelCount)
          ..setRange(0, pixelCount, buf.asTypedList(pixelCount)),
        mask: null,
        maskRowBytes: 0,
      );
    } finally {
      calloc.free(buf);
    }
  } finally {
    _deleteDC(hdc);
    calloc.free(bmi);
  }
}

// ---- ole32 + shell32: shell item images (IShellItemImageFactory) ----
//
// SHGetFileInfoW only exposes the system image list, whose "large" frame is
// 32 px — stretching that to the grid's 44 px tiles is what made icons look
// soft. IShellItemImageFactory is Explorer's own path: it follows .lnk/.url
// targets and renders the icon's real frame (up to the 256 px jumbo one).

final _coInitializeEx = _ole32.lookupFunction<
    Int32 Function(Pointer, Uint32),
    int Function(Pointer, int)>('CoInitializeEx');

const _coinitApartmentThreaded = 0x2;

final class Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

final _shCreateItemFromParsingName = _shell32.lookupFunction<
    Int32 Function(Pointer<Utf16>, Pointer, Pointer<Guid>, Pointer<IntPtr>),
    int Function(Pointer<Utf16>, Pointer, Pointer<Guid>,
        Pointer<IntPtr>)>('SHCreateItemFromParsingName');

// SIIGBF flags.
/// Take the icon, never a thumbnail.
const siigbfIconOnly = 0x00000004;
/// Fail instead of falling back to the file-type icon when no thumbnail
/// provider exists — the way to tell a real frame from a generic icon.
const siigbfThumbnailOnly = 0x00000008;
/// Let the provider return its native (larger) size instead of scaling down
/// to the requested box.
const siigbfBiggerSizeOk = 0x00000001;

typedef _GetImageC = Int32 Function(IntPtr, Int64, Uint32, Pointer<IntPtr>);
typedef _GetImageD = int Function(int, int, int, Pointer<IntPtr>);
typedef _ReleaseC = Uint32 Function(IntPtr);
typedef _ReleaseD = int Function(int);

/// Initializes COM on the calling isolate's thread. Every result is
/// acceptable: S_OK/S_FALSE mean it is up now, and RPC_E_CHANGED_MODE means
/// a different apartment was already picked — the shell item APIs below need
/// COM to exist, not a particular apartment.
void coInitialize() {
  _coInitializeEx(nullptr, _coinitApartmentThreaded);
}

/// Renders [path]'s image through IShellItemImageFactory into a box of
/// [cx] × [cy] px ([cy] defaults to [cx], a square box).
///
/// Returns an HBITMAP the caller must release with [deleteGdiObject], or 0.
/// With [siigbfThumbnailOnly] a 0 means "no thumbnail provider for this file
/// type", which is how the icon fallback is told apart from a real frame.
/// Requires [coInitialize] to have run on this thread.
int shellItemImageHandle(String path, int cx, {int? cy, int flags = siigbfIconOnly}) {
  final pathPtr = path.toNativeUtf16();
  final iid = calloc<Guid>();
  final item = calloc<IntPtr>();
  try {
    // IID_IShellItemImageFactory {BCC18B79-BA16-442F-80C4-8A59C30C463B}
    iid.ref
      ..data1 = 0xBCC18B79
      ..data2 = 0xBA16
      ..data3 = 0x442F;
    const tail = [0x80, 0xC4, 0x8A, 0x59, 0xC3, 0x0C, 0x46, 0x3B];
    for (var i = 0; i < tail.length; i++) {
      iid.ref.data4[i] = tail[i];
    }

    final hr = _shCreateItemFromParsingName(pathPtr, nullptr, iid, item);
    if (hr != 0 || item.value == 0) return 0;

    // IShellItemImageFactory vtable: [0] QueryInterface, [1] AddRef,
    // [2] Release, [3] GetImage.
    final vtbl = Pointer<IntPtr>.fromAddress(item.value).value;
    if (vtbl == 0) return 0;
    final entries = Pointer<IntPtr>.fromAddress(vtbl);
    final bitmap = calloc<IntPtr>();
    try {
      final getImage = Pointer<NativeFunction<_GetImageC>>.fromAddress(
              (entries + 3).value)
          .asFunction<_GetImageD>();
      // SIZE{cx, cy} is two LONGs passed by value in one 64-bit register.
      final packed = (cx & 0xFFFFFFFF) | ((cy ?? cx) << 32);
      final rc = getImage(item.value, packed, flags, bitmap);
      return rc == 0 ? bitmap.value : 0;
    } finally {
      final release = Pointer<NativeFunction<_ReleaseC>>.fromAddress(
              (entries + 2).value)
          .asFunction<_ReleaseD>();
      release(item.value);
      calloc.free(bitmap);
    }
  } finally {
    calloc.free(pathPtr);
    calloc.free(iid);
    calloc.free(item);
  }
}

// ---- comdlg32: the native open-file dialog ----

const _ofnNoChangeDir = 0x00000008;
const _ofnPathMustExist = 0x00000800;
const _ofnFileMustExist = 0x00001000;
const _ofnExplorer = 0x00080000;
const _ofnDontAddToRecent = 0x02000000;

/// OPENFILENAMEW. Field order and types must match the C struct; the ABI
/// padding between DWORD / pointer members is inserted by dart:ffi.
final class OpenFileNameW extends Struct {
  @Uint32()
  external int lStructSize;
  @IntPtr()
  external int hwndOwner;
  @IntPtr()
  external int hInstance;
  external Pointer<Utf16> lpstrFilter;
  external Pointer<Utf16> lpstrCustomFilter;
  @Uint32()
  external int nMaxCustFilter;
  @Uint32()
  external int nFilterIndex;
  external Pointer<Utf16> lpstrFile;
  @Uint32()
  external int nMaxFile;
  external Pointer<Utf16> lpstrFileTitle;
  @Uint32()
  external int nMaxFileTitle;
  external Pointer<Utf16> lpstrInitialDir;
  external Pointer<Utf16> lpstrTitle;
  @Uint32()
  external int flags;
  @Uint16()
  external int nFileOffset;
  @Uint16()
  external int nFileExtension;
  external Pointer<Utf16> lpstrDefExt;
  @IntPtr()
  external int lCustData;
  external Pointer<Void> lpfnHook;
  external Pointer<Utf16> lpTemplateName;
  external Pointer<Void> pvReserved;
  @Uint32()
  external int dwReserved;
  @Uint32()
  external int flagsEx;
}

final _getOpenFileNameW = _comdlg32.lookupFunction<
    Int32 Function(Pointer<OpenFileNameW>),
    int Function(Pointer<OpenFileNameW>)>('GetOpenFileNameW');
final _commDlgExtendedError = _comdlg32
    .lookupFunction<Uint32 Function(), int Function()>('CommDlgExtendedError');

/// Set by [pickImageFile]: 0 means the user cancelled, anything else is a
/// COMDLG32 error code (e.g. 0xFFFF for a struct the dialog rejected).
int lastFileDialogError = 0;

const _imageFilter =
    '图片 (*.png;*.jpg;*.jpeg;*.bmp;*.webp)\u0000'
    '*.png;*.jpg;*.jpeg;*.bmp;*.webp\u0000'
    '所有文件 (*.*)\u0000*.*\u0000\u0000';

/// Runs the native "open" dialog for picking a wallpaper. Returns the chosen
/// path, or null when the user cancels or the dialog cannot be shown
/// ([lastFileDialogError] then carries the code).
///
/// The dialog is modal to our window and blocks this isolate while it is up —
/// the same way any Win32 app drives it.
String? pickImageFile({String title = '选择背景图片'}) {
  final ofn = calloc<OpenFileNameW>();
  final buffer = calloc<Uint16>(1024);
  final filter = _imageFilter.toNativeUtf16();
  final titlePtr = title.toNativeUtf16();
  try {
    ofn.ref
      ..lStructSize = sizeOf<OpenFileNameW>()
      ..hwndOwner = findAppWindow()
      ..lpstrFilter = filter
      ..nFilterIndex = 1
      ..lpstrFile = buffer.cast<Utf16>()
      ..nMaxFile = 1024
      ..lpstrTitle = titlePtr
      ..flags = _ofnExplorer |
          _ofnFileMustExist |
          _ofnPathMustExist |
          _ofnNoChangeDir |
          _ofnDontAddToRecent;
    if (_getOpenFileNameW(ofn) == 0) {
      lastFileDialogError = _commDlgExtendedError();
      return null;
    }
    var len = 0;
    while (len < 1024 && buffer[len] != 0) {
      len++;
    }
    if (len == 0) return null;
    return String.fromCharCodes(buffer.asTypedList(len));
  } finally {
    calloc.free(ofn);
    calloc.free(buffer);
    calloc.free(filter);
    calloc.free(titlePtr);
  }
}

// ---- advapi32: registry reads (Steam and Wallpaper Engine install paths) ----

const hkeyCurrentUser = 0x80000001;
const hkeyLocalMachine = 0x80000002;
const _keyRead = 0x20019;
const _keyWow64_32 = 0x0100;
const _regSz = 1;

final _regOpenKeyExW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Uint32, Uint32, Pointer<IntPtr>),
    int Function(int, Pointer<Utf16>, int, int, Pointer<IntPtr>)>(
    'RegOpenKeyExW');
final _regQueryValueExW = _advapi32.lookupFunction<
    Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>),
    int Function(int, Pointer<Utf16>, Pointer<Uint32>, Pointer<Uint32>,
        Pointer<Uint8>, Pointer<Uint32>)>('RegQueryValueExW');
final _regCloseKey = _advapi32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('RegCloseKey');

/// Reads a REG_SZ value at `root\subKey` named [name], or null when the key
/// or value is absent. [wow32] reads the 32-bit view (where 32-bit installers
/// write their paths on 64-bit Windows).
String? readRegistryString(int root, String subKey, String name,
    {bool wow32 = false}) {
  final keyPtr = subKey.toNativeUtf16();
  final namePtr = name.toNativeUtf16();
  final hkey = calloc<IntPtr>();
  try {
    final access = wow32 ? _keyRead | _keyWow64_32 : _keyRead;
    if (_regOpenKeyExW(root, keyPtr, 0, access, hkey) != 0) return null;
    if (hkey.value == 0) return null;
    try {
      final type = calloc<Uint32>();
      final size = calloc<Uint32>();
      try {
        var rc = _regQueryValueExW(
            hkey.value, namePtr, nullptr, type, nullptr, size);
        if (rc != 0 || size.value < 2 || size.value > 1 << 16) return null;
        final buf = calloc<Uint8>(size.value + 2);
        try {
          rc = _regQueryValueExW(hkey.value, namePtr, nullptr, type, buf, size);
          if (rc != 0 || type.value != _regSz) return null;
          final chars = buf.cast<Uint16>();
          final max = size.value ~/ 2;
          var len = 0;
          while (len < max && chars[len] != 0) {
            len++;
          }
          return len == 0 ? null : String.fromCharCodes(chars.asTypedList(len));
        } finally {
          calloc.free(buf);
        }
      } finally {
        calloc.free(type);
        calloc.free(size);
      }
    } finally {
      _regCloseKey(hkey.value);
    }
  } finally {
    calloc.free(keyPtr);
    calloc.free(namePtr);
    calloc.free(hkey);
  }
}
