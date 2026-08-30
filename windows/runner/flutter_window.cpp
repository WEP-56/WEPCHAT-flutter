#include "flutter_window.h"

#include <optional>
#include <string>
#include <utility>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr const char kWindowChannel[] = "wepchat/window";

}  // namespace

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

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannel,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleWindowMethodCall(call, std::move(result));
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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  window_channel_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::HandleWindowMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    result->Error("no_window", "窗口句柄不可用");
    return;
  }

  const std::string& method = call.method_name();
  if (method == "isMaximized") {
    result->Success(flutter::EncodableValue(IsZoomed(hwnd) != FALSE));
    return;
  }
  if (method == "minimize") {
    ShowWindow(hwnd, SW_MINIMIZE);
    result->Success();
    return;
  }
  if (method == "toggleMaximize") {
    ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
    result->Success(flutter::EncodableValue(IsZoomed(hwnd) != FALSE));
    return;
  }
  if (method == "close") {
    PostMessage(hwnd, WM_CLOSE, 0, 0);
    result->Success();
    return;
  }
  if (method == "startDrag") {
    // 先回包再进入系统拖动循环：SendMessage 在拖动结束前不会返回。
    result->Success();
    ReleaseCapture();
    SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
    return;
  }
  if (method == "startResize") {
    const auto* edge = std::get_if<std::string>(call.arguments());
    if (edge == nullptr) {
      result->Error("bad_arguments", "startResize 需要一个边缘名称字符串");
      return;
    }
    WPARAM hit_test = 0;
    if (*edge == "top") {
      hit_test = HTTOP;
    } else if (*edge == "topLeft") {
      hit_test = HTTOPLEFT;
    } else if (*edge == "topRight") {
      hit_test = HTTOPRIGHT;
    } else {
      result->Error("bad_arguments", "不支持的窗口边缘：" + *edge);
      return;
    }
    result->Success();
    ReleaseCapture();
    SendMessage(hwnd, WM_NCLBUTTONDOWN, hit_test, 0);
    return;
  }

  result->NotImplemented();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
