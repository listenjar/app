#ifndef RUNNER_INSTANCE_H_
#define RUNNER_INSTANCE_H_

// One ListenJar window per build. The sign-in page in the browser opens
// <kUrlScheme>://sign-in (appScheme in lib/config.dart); Windows starts a
// second process for it, which focuses the running window and exits. So does
// a <kUrlScheme>://open?url=… link, or ListenJar.exe with a link, which the
// second process hands to the window first (lib/shared_links.dart).
// Debug builds use their own scheme and window class, so a dev build and an
// installed release don't take each other's links or windows.
#ifdef _DEBUG
inline constexpr wchar_t kUrlScheme[] = L"listenjar-dev";
inline constexpr wchar_t kWindowClassName[] = L"ListenJarDevWindow";
inline constexpr wchar_t kAppMutex[] = L"Local\\ListenJarDev";
#else
inline constexpr wchar_t kUrlScheme[] = L"listenjar";
inline constexpr wchar_t kWindowClassName[] = L"ListenJarWindow";
// Held while the app runs: the installer (tool/windows-installer.iss) waits
// for it to go before replacing the app.
inline constexpr wchar_t kAppMutex[] = L"Local\\ListenJar";
#endif

#include <windows.h>

#include <string>
#include <vector>

// WM_COPYDATA's dwData for a link handed to the running window: UTF-8.
inline constexpr ULONG_PTR kOpenLink = 0x4C4A4C4B;  // "LJLK"

// Hands [links] to the running window and brings it to the front. Returns
// false when there is none.
bool FocusRunningInstance(const std::vector<std::string>& links);

// Points kUrlScheme at this executable for the current user
// (HKCU\Software\Classes), so the link works however the app was installed.
void RegisterUrlScheme();

#endif  // RUNNER_INSTANCE_H_
