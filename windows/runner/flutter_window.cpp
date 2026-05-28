#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

namespace {

// Original window procedure of the Flutter view child window, saved so that
// all messages except WM_GETOBJECT can be forwarded to it.
WNDPROC g_flutter_view_original_proc = nullptr;

// Replacement window procedure for the Flutter view child window.
// Intercepts WM_GETOBJECT before the Flutter engine processes it, which
// prevents the Windows accessibility bridge from connecting and triggering
// AXTree corruption bugs in the Flutter Windows engine.
LRESULT CALLBACK FlutterViewWndProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) {
  if (message == WM_GETOBJECT) {
    return 0;
  }
  return ::CallWindowProc(g_flutter_view_original_proc, hwnd, message, wparam,
                          lparam);
}

}  // namespace

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

  HWND child_hwnd = flutter_controller_->view()->GetNativeWindow();
  SetChildContent(child_hwnd);

  // Hook the Flutter view child window so WM_GETOBJECT is blocked before the
  // Flutter engine sees it. This prevents the Windows accessibility bridge
  // from being established, which is the root cause of the AXTree crashes.
  g_flutter_view_original_proc = reinterpret_cast<WNDPROC>(
      ::SetWindowLongPtr(child_hwnd, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(FlutterViewWndProc)));

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Workaround for Flutter Windows accessibility bridge crash (AXTree bug).
  // Returning 0 for WM_GETOBJECT on the parent window prevents screen readers
  // from triggering the accessibility bridge via the top-level window as well.
  if (message == WM_GETOBJECT) {
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
