#include "updates.h"

#include <winsparkle.h>

#include <initializer_list>

namespace {

#ifdef LISTENJAR_UPDATE_PUBLIC_KEY
constexpr char kRegistryPath[] = "Software\\ListenJar\\Updates";
// Each architecture's own installer (tool/release.ts), as WinSparkle takes
// only an enclosure for the architecture it was built for.
#if defined(_M_ARM64)
#define LISTENJAR_APPCAST_PLATFORM "windows-arm64"
#else
#define LISTENJAR_APPCAST_PLATFORM "windows-x64"
#endif
constexpr char kAppcast[] =
    "https://github.com/listenjar/app/releases/latest/download/"
    "appcast-" LISTENJAR_APPCAST_PLATFORM ".xml";

#define LISTENJAR_WIDEN2(text) L##text
#define LISTENJAR_WIDEN(text) LISTENJAR_WIDEN2(text)
#define LISTENJAR_STRINGIFY2(value) #value
#define LISTENJAR_STRINGIFY(value) LISTENJAR_STRINGIFY2(value)

HWND window_ = nullptr;
bool started_ = false;

// WinSparkle asks the user on the second launch whether to check
// automatically. ListenJar checks by default, like the Mac app, unless a
// choice is already saved: per user, or per machine by an administrator.
bool PreferenceSaved() {
  for (HKEY root : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
    HKEY key;
    LSTATUS status = ::RegOpenKeyExA(root, kRegistryPath, 0, KEY_QUERY_VALUE, &key);
    if (status == ERROR_FILE_NOT_FOUND) {
      continue;
    }
    if (status != ERROR_SUCCESS) {
      return true;  // Unreadable: leave whatever is there alone.
    }
    status = ::RegQueryValueExA(key, "CheckForUpdates", nullptr, nullptr, nullptr, nullptr);
    ::RegCloseKey(key);
    if (status != ERROR_FILE_NOT_FOUND) {
      return true;
    }
  }
  return false;
}

// Called off the main thread, after WinSparkle has started the installer.
void __cdecl RequestShutdown() {
  ::PostMessageW(window_, kQuitForUpdate, 0, 0);
}
#endif

}  // namespace

void StartUpdates(HWND window) {
#ifdef LISTENJAR_UPDATE_PUBLIC_KEY
  window_ = window;
  if (!win_sparkle_set_eddsa_public_key(LISTENJAR_UPDATE_PUBLIC_KEY)) {
    return;
  }
  win_sparkle_set_appcast_url(kAppcast);
  // The version people see, and the build number appcasts compare
  // (pubspec.yaml's version: X.Y.Z+N).
  win_sparkle_set_app_details(
      L"ListenJar", L"ListenJar",
      LISTENJAR_WIDEN(LISTENJAR_STRINGIFY(FLUTTER_VERSION_MAJOR) "." LISTENJAR_STRINGIFY(
          FLUTTER_VERSION_MINOR) "." LISTENJAR_STRINGIFY(FLUTTER_VERSION_PATCH)));
  win_sparkle_set_app_build_version(LISTENJAR_WIDEN(LISTENJAR_STRINGIFY(FLUTTER_VERSION_BUILD)));
  win_sparkle_set_registry_path(kRegistryPath);
  win_sparkle_set_update_check_interval(24 * 60 * 60);
  win_sparkle_set_shutdown_request_callback(RequestShutdown);
  if (!PreferenceSaved()) {
    win_sparkle_set_automatic_check_for_updates(1);
  }
  win_sparkle_init();
  started_ = true;
#else
  (void)window;
#endif
}

void StopUpdates() {
#ifdef LISTENJAR_UPDATE_PUBLIC_KEY
  if (started_) {
    win_sparkle_cleanup();
    started_ = false;
  }
#endif
}

#define LISTENJAR_STRINGIFY_VERSION2(value) #value
#define LISTENJAR_STRINGIFY_VERSION(value) LISTENJAR_STRINGIFY_VERSION2(value)

const char* AppVersion() {
#if defined(FLUTTER_VERSION_MAJOR) && defined(FLUTTER_VERSION_MINOR) && defined(FLUTTER_VERSION_PATCH)
  return LISTENJAR_STRINGIFY_VERSION(FLUTTER_VERSION_MAJOR) "." LISTENJAR_STRINGIFY_VERSION(
      FLUTTER_VERSION_MINOR) "." LISTENJAR_STRINGIFY_VERSION(FLUTTER_VERSION_PATCH);
#else
  return "";
#endif
}

bool UpdatesAvailable() {
#ifdef LISTENJAR_UPDATE_PUBLIC_KEY
  return started_;
#else
  return false;
#endif
}

void CheckForUpdates() {
  if (UpdatesAvailable()) {
    win_sparkle_check_update_with_ui();
  }
}

bool AutomaticUpdates() {
  return UpdatesAvailable() && win_sparkle_get_automatic_check_for_updates() != 0;
}

void SetAutomaticUpdates(bool enabled) {
  if (UpdatesAvailable()) {
    win_sparkle_set_automatic_check_for_updates(enabled ? 1 : 0);
  }
}
