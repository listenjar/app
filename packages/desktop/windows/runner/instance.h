#ifndef RUNNER_INSTANCE_H_
#define RUNNER_INSTANCE_H_

// One ListenJar window per build. The sign-in page in the browser opens
// <kUrlScheme>://sign-in (appScheme in lib/config.dart); Windows starts a
// second process for it, which focuses the running window and exits.
// Debug builds use their own scheme and window class, so a dev build and an
// installed release don't take each other's links or windows.
#ifdef _DEBUG
inline constexpr wchar_t kUrlScheme[] = L"listenjar-dev";
inline constexpr wchar_t kWindowClassName[] = L"ListenJarDevWindow";
#else
inline constexpr wchar_t kUrlScheme[] = L"listenjar";
inline constexpr wchar_t kWindowClassName[] = L"ListenJarWindow";
#endif

// Brings the running window to the front. Returns false when there is none.
bool FocusRunningInstance();

// Points kUrlScheme at this executable for the current user
// (HKCU\Software\Classes), so the link works however the app was installed.
void RegisterUrlScheme();

#endif  // RUNNER_INSTANCE_H_
