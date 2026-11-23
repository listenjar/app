#include "instance.h"

#include <windows.h>

#include <string>

bool FocusRunningInstance() {
  HWND window = ::FindWindowW(kWindowClassName, nullptr);
  if (window == nullptr) {
    return false;
  }
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  // The browser that opened the link is in the foreground and started this
  // process, which may therefore hand the foreground on.
  ::SetForegroundWindow(window);
  return true;
}

namespace {

bool SetValue(HKEY root, const std::wstring& key, const wchar_t* name,
              const std::wstring& value) {
  HKEY handle;
  if (::RegCreateKeyExW(root, key.c_str(), 0, nullptr, 0, KEY_SET_VALUE,
                        nullptr, &handle, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  LSTATUS status = ::RegSetValueExW(
      handle, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(handle);
  return status == ERROR_SUCCESS;
}

}  // namespace

void RegisterUrlScheme() {
  wchar_t path[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (length == 0 || length == MAX_PATH) {
    return;
  }
  const std::wstring key = std::wstring(L"Software\\Classes\\") + kUrlScheme;
  SetValue(HKEY_CURRENT_USER, key, nullptr, L"URL:ListenJar");
  SetValue(HKEY_CURRENT_USER, key, L"URL Protocol", L"");
  SetValue(HKEY_CURRENT_USER, key + L"\\shell\\open\\command", nullptr,
           L"\"" + std::wstring(path, length) + L"\" \"%1\"");
}
