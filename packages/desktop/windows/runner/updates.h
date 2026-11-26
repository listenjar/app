#ifndef RUNNER_UPDATES_H_
#define RUNNER_UPDATES_H_

#include <windows.h>

// In-app updates with WinSparkle, for lib/updates.dart: the appcast on
// listenjar/app's latest GitHub release, whose installers are signed with
// the Ed25519 key release builds carry (LISTENJAR_UPDATE_PUBLIC_KEY, which
// CMakeLists.txt takes from the environment). Debug and local builds have no
// key, so no updater. WinSparkle keeps its preferences under
// HKCU\Software\ListenJar\Updates.

// Asks the window to close for good, so the installer WinSparkle has started
// can replace the app (tool/windows-installer.iss waits for it).
inline constexpr UINT kQuitForUpdate = WM_APP + 0x4C4A;  // "LJ"

// Starts checking, every day unless turned off. Does nothing without a key.
void StartUpdates(HWND window);

// Stops WinSparkle's thread before the app exits.
void StopUpdates();

// Whether this build has an updater.
bool UpdatesAvailable();

// The version people see: pubspec.yaml's X.Y.Z.
const char* AppVersion();

// Checks now, showing WinSparkle's window either way.
void CheckForUpdates();

// Whether WinSparkle checks on its own. A change takes effect the next time
// the app starts: WinSparkle starts its checker once.
bool AutomaticUpdates();
void SetAutomaticUpdates(bool enabled);

#endif  // RUNNER_UPDATES_H_
