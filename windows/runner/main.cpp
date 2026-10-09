#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Single-instance guard. The launcher owns the whole desktop shell, so a
// second copy would only fight the first over the same screen. Held for the
// lifetime of the process; a second launch finds ERROR_ALREADY_EXISTS, raises
// the existing window and bows out. The window class is the one
// win32_window.cpp registers; the title is the one window.Create is given.
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\XGameDesktop.SingleInstance";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"xgame_desktop";

void RaiseExistingWindow() {
  HWND existing = ::FindWindowW(kWindowClass, kWindowTitle);
  if (existing == nullptr) {
    // Between the mutex check and here the first copy may still be starting
    // up; nothing to raise, and the guard itself has done the job.
    return;
  }
  WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
  if (::GetWindowPlacement(existing, &placement) &&
      placement.showCmd == SW_SHOWMINIMIZED) {
    ::ShowWindow(existing, SW_RESTORE);
  }
  ::BringWindowToTop(existing);
  ::SetForegroundWindow(existing);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HANDLE single_instance = ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (single_instance == nullptr ||
      ::GetLastError() == ERROR_ALREADY_EXISTS) {
    RaiseExistingWindow();
    if (single_instance != nullptr) {
      ::CloseHandle(single_instance);
    }
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1440, 900);
  if (!window.Create(L"xgame_desktop", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::ReleaseMutex(single_instance);
  ::CloseHandle(single_instance);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
