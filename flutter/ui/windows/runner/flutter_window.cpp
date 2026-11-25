#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cwchar>
#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// The top-level SX Studio window of process |pid|, shown or hidden.
HWND FindWindowOf(DWORD pid) {
  struct Search {
    DWORD pid;
    HWND found;
  } search{pid, nullptr};
  ::EnumWindows(
      [](HWND hwnd, LPARAM param) -> BOOL {
        auto* s = reinterpret_cast<Search*>(param);
        DWORD owner = 0;
        ::GetWindowThreadProcessId(hwnd, &owner);
        if (owner != s->pid) return TRUE;
        wchar_t name[64] = {};
        ::GetClassNameW(hwnd, name, 64);
        if (wcscmp(name, kWindowClass) != 0) return TRUE;
        s->found = hwnd;
        return FALSE;
      },
      reinterpret_cast<LPARAM>(&search));
  return search.found;
}

}  // namespace

UINT ShowWindowMessage() {
  static UINT message = ::RegisterWindowMessageW(L"XSVProductions.SXStudio.Show");
  return message;
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "sx/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        // showOther(pid): the copy already running brings up its window
        if (call.method_name() == "showOther") {
          const auto* pid = std::get_if<int32_t>(call.arguments());
          HWND other = pid ? FindWindowOf(static_cast<DWORD>(*pid)) : nullptr;
          if (other) {
            ::AllowSetForegroundWindow(static_cast<DWORD>(*pid));
            ::PostMessageW(other, ShowWindowMessage(), 0, 0);
          }
          result->Success(flutter::EncodableValue(other != nullptr));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Closing the window only hides it, as closing the old app's browser window
  // left its server running: the lights, the player, the Auto Show and the
  // phones carry on, and the app quits by itself later (lifetime.dart).
  if (message == WM_CLOSE) {
    ::ShowWindow(hwnd, SW_HIDE);
    if (channel_) channel_->InvokeMethod("closed", nullptr);
    return 0;
  }
  // Started again: show this window instead.
  if (message == ShowWindowMessage()) {
    ::ShowWindow(hwnd, ::IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    ::SetForegroundWindow(hwnd);
    if (channel_) channel_->InvokeMethod("opened", nullptr);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
