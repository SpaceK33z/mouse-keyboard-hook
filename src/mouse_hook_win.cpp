#include <windows.h>
#include <atlstr.h>
#include <atomic>
#include <thread>
#include <string>
#include <napi.h>
#include <psapi.h>
#include <algorithm>
#include <shellscalingapi.h>

static std::atomic<bool> g_running{false};
static Napi::ThreadSafeFunction g_tsfn;
static HHOOK g_mouseHook = nullptr;
static HHOOK g_keyboardHook = nullptr;
static std::thread g_loopThread;
static DWORD g_loopThreadId = 0;

// Click tracking state
static DWORD g_lastClickTime = 0;
static POINT g_lastClickPoint = {0, 0};
static int g_clickCount = 0;
static int g_lastClickButton = -1;

// Helper function to get filename from path
std::string getFileName(const std::string &value) {
  char separator = '\\';
  size_t index = value.rfind(separator, value.length());

  if (index != std::string::npos) {
    return (value.substr(index + 1, value.length() - index));
  }

  return ("");
}

// Convert wstring to UTF-8 string
std::string toUtf8(const std::wstring &str) {
  std::string ret;
  int len = WideCharToMultiByte(CP_UTF8, 0, str.c_str(), str.length(), NULL, 0, NULL, NULL);
  if (len > 0) {
    ret.resize(len);
    WideCharToMultiByte(CP_UTF8, 0, str.c_str(), str.length(), &ret[0], len, NULL, NULL);
  }
  return ret;
}


// Return description from file version info
// Copied from get-windows: https://github.com/sindresorhus/get-windows/blob/cafa0f661c425f33f6b1f209a53c3b8738f93ffb/Sources/windows/main.cc
std::string getDescriptionFromFileVersionInfo(const BYTE *pBlock) {
  UINT bufLen = 0;
  struct LANGANDCODEPAGE {
    WORD wLanguage;
    WORD wCodePage;
  } * lpTranslate;

  LANGANDCODEPAGE codePage{0x040904E4};
  // Get language struct
  if (VerQueryValueW((LPVOID *)pBlock, (LPCWSTR)L"\\VarFileInfo\\Translation", (LPVOID *)&lpTranslate, &bufLen)) {
    codePage = lpTranslate[0];
  }

  wchar_t fileDescriptionKey[256];
  wsprintfW(fileDescriptionKey, L"\\StringFileInfo\\%04x%04x\\FileDescription", codePage.wLanguage, codePage.wCodePage);
  wchar_t *fileDescription = NULL;
  UINT fileDescriptionSize;
  // Get description file
  if (VerQueryValueW((LPVOID *)pBlock, fileDescriptionKey, (LPVOID *)&fileDescription, &fileDescriptionSize)) {
    return toUtf8(fileDescription);
  }

  return "";
}

// Get process path and name with better app name
std::string getProcessName(const HANDLE &hProcess) {
  DWORD dwSize{MAX_PATH};
  wchar_t exeName[MAX_PATH]{};
  QueryFullProcessImageNameW(hProcess, 0, exeName, &dwSize);
  std::string path = toUtf8(exeName);
  std::string name = getFileName(path);

  DWORD dwHandle = 0;
  wchar_t *wspath(exeName);
  DWORD infoSize = GetFileVersionInfoSizeW(wspath, &dwHandle);

  if (infoSize != 0) {
    BYTE *pVersionInfo = new BYTE[infoSize];
    std::unique_ptr<BYTE[]> skey_automatic_cleanup(pVersionInfo);
    if (GetFileVersionInfoW(wspath, NULL, infoSize, pVersionInfo) != 0) {
      std::string nname = getDescriptionFromFileVersionInfo(pVersionInfo);
      if (nname != "") {
        name = nname;
      }
    }
  }

  return name;
}


// Helper function to get window title and app name from a point
static std::tuple<std::string, std::string> GetWindowInfoFromPoint(POINT pt) {
  HWND hwnd = WindowFromPoint(pt);
  if (!hwnd) return {"", ""};

  // Get the window text
  WCHAR title[256] = {0};
  int len = GetWindowTextW(hwnd, title, 255);
  std::string titleStr = "";
  if (len > 0) {
    // Convert to UTF-8
    int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, title, len, NULL, 0, NULL, NULL);
    if (sizeNeeded > 0) {
      titleStr.resize(sizeNeeded);
      WideCharToMultiByte(CP_UTF8, 0, title, len, &titleStr[0], sizeNeeded, NULL, NULL);
    }
  }

  // Get the app name using the better approach
  std::string appName = "";
  DWORD processId = 0;
  GetWindowThreadProcessId(hwnd, &processId);
  if (processId > 0) {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (hProcess) {
      appName = getProcessName(hProcess);
      CloseHandle(hProcess);
    }
  }

  return {titleStr, appName};
}

// Helper function to get window title and app name from active window
static std::tuple<std::string, std::string> GetActiveWindowInfo() {
  HWND hwnd = GetForegroundWindow();
  if (!hwnd) return {"", ""};

  // Get the window text
  WCHAR title[256] = {0};
  int len = GetWindowTextW(hwnd, title, 255);
  std::string titleStr = "";
  if (len > 0) {
    // Convert to UTF-8
    int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, title, len, NULL, 0, NULL, NULL);
    if (sizeNeeded > 0) {
      titleStr.resize(sizeNeeded);
      WideCharToMultiByte(CP_UTF8, 0, title, len, &titleStr[0], sizeNeeded, NULL, NULL);
    }
  }

  // Get the app name using the better approach
  std::string appName = "";
  DWORD processId = 0;
  GetWindowThreadProcessId(hwnd, &processId);
  if (processId > 0) {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (hProcess) {
      appName = getProcessName(hProcess);
      CloseHandle(hProcess);
    }
  }

  return {titleStr, appName};
}

static const char* MouseTypeToName(WPARAM wParam) {
  switch (wParam) {
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
      return "mousedown";
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
      return "mouseup";
    case WM_MOUSEMOVE:
    case WM_LBUTTONDBLCLK:
    case WM_RBUTTONDBLCLK:
    case WM_MBUTTONDBLCLK:
    default:
      return "mousedrag"; // we will send drag on move while buttons held
  }
}

static int GetButtonFromParams(WPARAM wParam) {
  switch (wParam) {
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP:
    case WM_LBUTTONDBLCLK:
      return 0; // left
    case WM_RBUTTONDOWN:
    case WM_RBUTTONUP:
    case WM_RBUTTONDBLCLK:
      return 1; // right
    case WM_MBUTTONDOWN:
    case WM_MBUTTONUP:
    case WM_MBUTTONDBLCLK:
      return 2; // middle
    default:
      return 0;
  }
}

static LRESULT CALLBACK LowLevelMouseProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode < 0 || !g_running.load()) {
    return CallNextHookEx(nullptr, nCode, wParam, lParam);
  }

  PMSLLHOOKSTRUCT ms = reinterpret_cast<PMSLLHOOKSTRUCT>(lParam);
  POINT p = ms->pt; // use physical pixel coordinates directly

  // modifier keys
  bool metaKey = (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000);
  bool altKey = (GetKeyState(VK_MENU) & 0x8000) != 0;
  bool shiftKey = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  bool ctrlKey = (GetKeyState(VK_CONTROL) & 0x8000) != 0;

  const char* type = MouseTypeToName(wParam);
  int button = GetButtonFromParams(wParam);
  int clicks = 0;

  // For WM_MOUSEMOVE, only emit mousedrag when any button is down
  if (wParam == WM_MOUSEMOVE) {
    bool anyDown = (GetKeyState(VK_LBUTTON) & 0x8000) ||
                   (GetKeyState(VK_RBUTTON) & 0x8000) ||
                   (GetKeyState(VK_MBUTTON) & 0x8000);
    if (!anyDown) {
      return CallNextHookEx(nullptr, nCode, wParam, lParam);
    }
    type = "mousedrag";
    if (GetKeyState(VK_LBUTTON) & 0x8000) button = 0;
    else if (GetKeyState(VK_RBUTTON) & 0x8000) button = 1;
    else if (GetKeyState(VK_MBUTTON) & 0x8000) button = 2;
  }

  // Determine click count using system double-click time and a small move threshold
  if (wParam == WM_LBUTTONDOWN || wParam == WM_RBUTTONDOWN || wParam == WM_MBUTTONDOWN) {
    DWORD now = GetTickCount();
    UINT dct = GetDoubleClickTime();
    int dx = std::abs(p.x - g_lastClickPoint.x);
    int dy = std::abs(p.y - g_lastClickPoint.y);
    // Accept small movement within SM_CXDOUBLECLK/SM_CYDOUBLECLK region
    int threshX = GetSystemMetrics(SM_CXDOUBLECLK) / 2;
    int threshY = GetSystemMetrics(SM_CYDOUBLECLK) / 2;

    if (g_lastClickButton == button && (now - g_lastClickTime) <= dct && dx <= threshX && dy <= threshY) {
      g_clickCount += 1;
    } else {
      g_clickCount = 1;
    }

    g_lastClickTime = now;
    g_lastClickPoint = p;
    g_lastClickButton = button;
    clicks = g_clickCount;
  } else if (wParam == WM_LBUTTONUP || wParam == WM_RBUTTONUP || wParam == WM_MBUTTONUP) {
    clicks = g_clickCount;
  } else {
    // for drag, don't increment
    clicks = g_clickCount;
  }

  // Get window title and app name from the point
  auto windowInfo = GetWindowInfoFromPoint(p);
  std::string windowTitle = std::get<0>(windowInfo);
  std::string windowAppName = std::get<1>(windowInfo);

  // Get DPI info for debugging
  HMONITOR hMonitor = MonitorFromPoint(p, MONITOR_DEFAULTTONEAREST);
  UINT dpiX = 96, dpiY = 96;
  if (hMonitor && GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY) != S_OK) {
    dpiX = dpiY = 96;
  }

  g_tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", type);
    obj.Set("x", static_cast<double>(p.x));
    obj.Set("y", static_cast<double>(p.y));
    obj.Set("button", button);
    obj.Set("clicks", clicks);
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);
    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
    obj.Set("dpiX", static_cast<double>(dpiX));
    obj.Set("dpiY", static_cast<double>(dpiY));

    // Add system DPI for comparison
    HDC hdc = GetDC(NULL);
    int systemDpiX = hdc ? GetDeviceCaps(hdc, LOGPIXELSX) : 96;
    int systemDpiY = hdc ? GetDeviceCaps(hdc, LOGPIXELSY) : 96;
    if (hdc) ReleaseDC(NULL, hdc);
    obj.Set("systemDpiX", static_cast<double>(systemDpiX));
    obj.Set("systemDpiY", static_cast<double>(systemDpiY));
    cb.Call({ obj });
  });

  return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

static LRESULT CALLBACK LowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) {
  if (nCode < 0 || !g_running.load()) {
    return CallNextHookEx(nullptr, nCode, wParam, lParam);
  }
  if (wParam != WM_KEYDOWN && wParam != WM_SYSKEYDOWN) {
    return CallNextHookEx(nullptr, nCode, wParam, lParam);
  }

  KBDLLHOOKSTRUCT* kb = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
  DWORD vkCode = kb->vkCode;

  // Translate to Unicode char if possible
  BYTE keyboardState[256];
  GetKeyboardState(keyboardState);
  UINT scanCode = MapVirtualKeyW(vkCode, MAPVK_VK_TO_VSC);
  WCHAR unicodeBuf[5] = {0};
  int unicodeLen = ToUnicode(vkCode, scanCode, keyboardState, unicodeBuf, 4, 0);
  std::string key = "";
  if (unicodeLen > 0) {
    int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, unicodeBuf, unicodeLen, NULL, 0, NULL, NULL);
    key.resize(sizeNeeded);
    WideCharToMultiByte(CP_UTF8, 0, unicodeBuf, unicodeLen, &key[0], sizeNeeded, NULL, NULL);
  }
  int32_t keychar = unicodeLen > 0 ? static_cast<int32_t>(unicodeBuf[0]) : 0;

  bool metaKey = (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000);
  bool altKey = (GetKeyState(VK_MENU) & 0x8000) != 0;
  bool shiftKey = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  bool ctrlKey = (GetKeyState(VK_CONTROL) & 0x8000) != 0;

  // Get current mouse position and convert to match mouse event coordinates
  POINT mousePos;
  bool usedPhysicalCursor = GetPhysicalCursorPos(&mousePos);
  UINT dpiX = 96, dpiY = 96;

  if (!usedPhysicalCursor) {
    // Fallback: GetCursorPos gives logical coords, convert to physical
    GetCursorPos(&mousePos);
    HMONITOR hMonitor = MonitorFromPoint(mousePos, MONITOR_DEFAULTTONEAREST);
    if (hMonitor && GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY) == S_OK) {
      if (dpiX == 0) dpiX = 96;
      if (dpiY == 0) dpiY = 96;
      mousePos.x = MulDiv(mousePos.x, dpiX, 96);
      mousePos.y = MulDiv(mousePos.y, dpiY, 96);
    }
  } else {
    // GetPhysicalCursorPos worked, but we need to scale to match MSLLHOOKSTRUCT coords
    // Get system DPI scaling factor
    HMONITOR hMonitor = MonitorFromPoint(mousePos, MONITOR_DEFAULTTONEAREST);
    if (hMonitor && GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY) == S_OK) {
      if (dpiX == 0) dpiX = 96;
      if (dpiY == 0) dpiY = 96;
      // Scale from GetPhysicalCursorPos coords to MSLLHOOKSTRUCT coords
      mousePos.x = MulDiv(mousePos.x, dpiX, 96);
      mousePos.y = MulDiv(mousePos.y, dpiY, 96);
    } else {
      // If DPI detection fails, use system DPI
      HDC hdc = GetDC(NULL);
      if (hdc) {
        dpiX = GetDeviceCaps(hdc, LOGPIXELSX);
        dpiY = GetDeviceCaps(hdc, LOGPIXELSY);
        ReleaseDC(NULL, hdc);
        mousePos.x = MulDiv(mousePos.x, dpiX, 96);
        mousePos.y = MulDiv(mousePos.y, dpiY, 96);
      }
    }
  }

  // Get window title and app name from the active window
  auto windowInfo = GetActiveWindowInfo();
  std::string windowTitle = std::get<0>(windowInfo);
  std::string windowAppName = std::get<1>(windowInfo);

  g_tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", "keypress");
    obj.Set("keychar", keychar);
    obj.Set("key", key);
    obj.Set("x", static_cast<double>(mousePos.x));
    obj.Set("y", static_cast<double>(mousePos.y));
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);
    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
    obj.Set("dpiX", static_cast<double>(dpiX));
    obj.Set("dpiY", static_cast<double>(dpiY));
    obj.Set("usedPhysicalCursor", usedPhysicalCursor);

    // Add system DPI for comparison
    HDC hdc = GetDC(NULL);
    int systemDpiX = hdc ? GetDeviceCaps(hdc, LOGPIXELSX) : 96;
    int systemDpiY = hdc ? GetDeviceCaps(hdc, LOGPIXELSY) : 96;
    if (hdc) ReleaseDC(NULL, hdc);
    obj.Set("systemDpiX", static_cast<double>(systemDpiX));
    obj.Set("systemDpiY", static_cast<double>(systemDpiY));
    cb.Call({ obj });
  });

  return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

class Hook : public Napi::ObjectWrap<Hook> {
public:
  static Napi::Object Init(Napi::Env env, Napi::Object exports) {
    Napi::Function func = DefineClass(env, "Hook", {
      InstanceMethod("start", &Hook::Start),
      InstanceMethod("stop", &Hook::Stop)
    });
    exports.Set("Hook", func);
    return exports;
  }

  Hook(const Napi::CallbackInfo& info) : Napi::ObjectWrap<Hook>(info) {
    Napi::Env env = info.Env();
    if (info.Length() != 1 || !info[0].IsFunction()) {
      Napi::TypeError::New(env, "Expected callback").ThrowAsJavaScriptException();
      return;
    }
    g_tsfn = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(), "mousekbcb", 0, 1);
  }

  Napi::Value Start(const Napi::CallbackInfo& info) {
    if (g_running.exchange(true)) return info.Env().Undefined();

    g_loopThread = std::thread([](){
      // Install low-level hooks on this thread and pump messages
      g_loopThreadId = GetCurrentThreadId();
      g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, LowLevelMouseProc, GetModuleHandleW(NULL), 0);
      g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc, GetModuleHandleW(NULL), 0);
      if (!g_mouseHook || !g_keyboardHook) {
        g_running.store(false);
        return;
      }

      MSG msg;
      while (g_running.load() && GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
      }
    });

    return info.Env().Undefined();
  }

  Napi::Value Stop(const Napi::CallbackInfo& info) {
    if (!g_running.exchange(false)) return info.Env().Undefined();

    if (g_mouseHook) { UnhookWindowsHookEx(g_mouseHook); g_mouseHook = nullptr; }
    if (g_keyboardHook) { UnhookWindowsHookEx(g_keyboardHook); g_keyboardHook = nullptr; }

    // Post a quit message to break GetMessage loop
    if (g_loopThreadId != 0) {
      PostThreadMessageW(g_loopThreadId, WM_QUIT, 0, 0);
    }
    if (g_loopThread.joinable()) g_loopThread.join();

    if (g_tsfn) g_tsfn.Release();
    return info.Env().Undefined();
  }
};

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  return Hook::Init(env, exports);
}

NODE_API_MODULE(mouse_hook, InitAll)


