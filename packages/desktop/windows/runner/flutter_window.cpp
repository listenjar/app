#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "instance.h"
#include "updates.h"

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
  links_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "listenjar/links",
      &flutter::StandardMethodCodec::GetInstance());
  // The launch's own link arrives as a main() argument: none wait here.
  links_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "pending") {
      result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    } else {
      result->NotImplemented();
    }
  });
  StartUpdates(GetHandle());
  updates_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "listenjar/updates",
      &flutter::StandardMethodCodec::GetInstance());
  updates_->SetMethodCallHandler([](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "check") {
      CheckForUpdates();
      result->Success();
      return;
    }
    if (method == "setAutomatic") {
      const auto* enabled = std::get_if<bool>(call.arguments());
      SetAutomaticUpdates(enabled == nullptr || *enabled);
    } else if (method != "state") {
      result->NotImplemented();
      return;
    }
    flutter::EncodableMap state{
        {flutter::EncodableValue("available"), flutter::EncodableValue(UpdatesAvailable())},
        {flutter::EncodableValue("version"), flutter::EncodableValue(std::string(AppVersion()))}};
    if (UpdatesAvailable()) {
      state[flutter::EncodableValue("canCheck")] = flutter::EncodableValue(true);
      state[flutter::EncodableValue("automatic")] = flutter::EncodableValue(AutomaticUpdates());
    }
    result->Success(flutter::EncodableValue(state));
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
  StopUpdates();
  updates_ = nullptr;
  links_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case kQuitForUpdate:
      // WinSparkle has started the installer: quit, not just hide.
      Destroy();
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_COPYDATA: {
      const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
      if (data && data->dwData == kOpenLink && links_) {
        std::string link(static_cast<const char*>(data->lpData), data->cbData);
        links_->InvokeMethod(
            "open", std::make_unique<flutter::EncodableValue>(link));
        return TRUE;
      }
      break;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
