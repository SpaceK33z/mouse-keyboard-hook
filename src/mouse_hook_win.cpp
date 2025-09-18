#include <windows.h>
#include <atlstr.h>
#include <atomic>
#include <thread>
#include <string>
#include <napi.h>

static std::atomic<bool> g_running{false};
static Napi::ThreadSafeFunction g_tsfn;
static HHOOK g_mouseHook = nullptr;
static HHOOK g_keyboardHook = nullptr;
static std::thread g_loopThread;
static DWORD g_loopThreadId = 0;

// Helper function to get window title and app name from a point
static std::pair<std::string, std::string> GetWindowInfoFromPoint(POINT pt) {
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

  // Get the app name
  std::string appName = "";
  DWORD processId = 0;
  GetWindowThreadProcessId(hwnd, &processId);
  if (processId > 0) {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, processId);
    if (hProcess) {
      WCHAR exePath[MAX_PATH] = {0};
      DWORD pathLen = MAX_PATH;
      if (QueryFullProcessImageNameW(hProcess, 0, exePath, &pathLen)) {
        // Extract just the filename from the full path
        WCHAR* fileName = wcsrchr(exePath, L'\\');
        if (fileName) {
          fileName++; // Skip the backslash
          // Remove .exe extension if present
          WCHAR* ext = wcsrchr(fileName, L'.');
          if (ext && _wcsicmp(ext, L".exe") == 0) {
            *ext = L'\0';
          }

          // Convert to UTF-8
          int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, fileName, -1, NULL, 0, NULL, NULL);
          if (sizeNeeded > 0) {
            appName.resize(sizeNeeded - 1); // -1 to exclude null terminator
            WideCharToMultiByte(CP_UTF8, 0, fileName, -1, &appName[0], sizeNeeded, NULL, NULL);
          }
        }
      }
      CloseHandle(hProcess);
    }
  }

  return {titleStr, appName};
}

// Helper function to get window title and app name from active window
static std::pair<std::string, std::string> GetActiveWindowInfo() {
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

  // Get the app name
  std::string appName = "";
  DWORD processId = 0;
  GetWindowThreadProcessId(hwnd, &processId);
  if (processId > 0) {
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, processId);
    if (hProcess) {
      WCHAR exePath[MAX_PATH] = {0};
      DWORD pathLen = MAX_PATH;
      if (QueryFullProcessImageNameW(hProcess, 0, exePath, &pathLen)) {
        // Extract just the filename from the full path
        WCHAR* fileName = wcsrchr(exePath, L'\\');
        if (fileName) {
          fileName++; // Skip the backslash
          // Remove .exe extension if present
          WCHAR* ext = wcsrchr(fileName, L'.');
          if (ext && _wcsicmp(ext, L".exe") == 0) {
            *ext = L'\0';
          }

          // Convert to UTF-8
          int sizeNeeded = WideCharToMultiByte(CP_UTF8, 0, fileName, -1, NULL, 0, NULL, NULL);
          if (sizeNeeded > 0) {
            appName.resize(sizeNeeded - 1); // -1 to exclude null terminator
            WideCharToMultiByte(CP_UTF8, 0, fileName, -1, &appName[0], sizeNeeded, NULL, NULL);
          }
        }
      }
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
  POINT p = ms->pt;

  // modifier keys
  bool metaKey = (GetKeyState(VK_LWIN) & 0x8000) || (GetKeyState(VK_RWIN) & 0x8000);
  bool altKey = (GetKeyState(VK_MENU) & 0x8000) != 0;
  bool shiftKey = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  bool ctrlKey = (GetKeyState(VK_CONTROL) & 0x8000) != 0;

  const char* type = MouseTypeToName(wParam);
  int button = GetButtonFromParams(wParam);

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

  // Get window title and app name from the point
  auto windowInfo = GetWindowInfoFromPoint(p);
  std::string windowTitle = windowInfo.first;
  std::string windowAppName = windowInfo.second;

  g_tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", type);
    obj.Set("x", static_cast<double>(p.x));
    obj.Set("y", static_cast<double>(p.y));
    obj.Set("button", button);
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);
    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
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

  // Get window title and app name from the active window
  auto windowInfo = GetActiveWindowInfo();
  std::string windowTitle = windowInfo.first;
  std::string windowAppName = windowInfo.second;

  g_tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", "keypress");
    obj.Set("keychar", keychar);
    obj.Set("key", key);
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);
    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
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


