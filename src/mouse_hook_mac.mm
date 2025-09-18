#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <thread>
#include <napi.h>
#include <Cocoa/Cocoa.h>
#include <Carbon/Carbon.h>

static CFMachPortRef tap = nullptr;
static CFRunLoopSourceRef runLoopSource = nullptr;
static std::atomic<bool> running{false};
static Napi::ThreadSafeFunction tsfn;

// Helper function to convert CFString to std::string
static std::string CFStringToStdString(CFStringRef cfString) {
  if (!cfString) return "";

  CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(cfString), kCFStringEncodingUTF8);
  char* utf8Buffer = new char[maxSize + 1];
  std::string result = "";

  if (CFStringGetCString(cfString, utf8Buffer, maxSize + 1, kCFStringEncodingUTF8)) {
    result = std::string(utf8Buffer);
  }

  delete[] utf8Buffer;
  return result;
}

// Helper function to run AppleScript and get browser URL
static std::string GetBrowserURL(const std::string& bundleId) {
  // List of supported browsers
  std::vector<std::string> supportedBrowsers = {
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
    "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
    "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary",
    "com.mighty.app", "com.ghostbrowser.gb1", "com.bookry.wavebox", "com.pushplaylabs.sidekick",
    "com.operasoftware.Opera", "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper", "com.operasoftware.OperaGX",
    "com.vivaldi.Vivaldi", "company.thebrowser.Browser"
  };

  // Check if it's a supported browser
  bool isSupported = false;
  for (const auto& browser : supportedBrowsers) {
    if (bundleId == browser) {
      isSupported = true;
      break;
    }
  }

  if (!isSupported) {
    // Check for Safari
    if (bundleId == "com.apple.Safari" || bundleId == "com.apple.SafariTechnologyPreview") {
      isSupported = true;
    }
  }

  if (!isSupported) return "";

  // Check accessibility permissions
  if (!AXIsProcessTrustedWithOptions(nullptr)) {
    return "";
  }

  // Build AppleScript command
  std::string script;
  if (bundleId == "com.apple.Safari" || bundleId == "com.apple.SafariTechnologyPreview") {
    script = "tell app id \"" + bundleId + "\" to get URL of front document";
  } else {
    script = "tell app id \"" + bundleId + "\" to get the URL of active tab of front window";
  }

  // Execute AppleScript
  NSAppleScript* appleScript = [[NSAppleScript alloc] initWithSource:[NSString stringWithUTF8String:script.c_str()]];
  NSAppleEventDescriptor* result = [appleScript executeAndReturnError:nil];

  if (result) {
    return std::string([[result stringValue] UTF8String]);
  }

  return "";
}

// Helper function to get window information from a point
static std::tuple<std::string, std::string, std::string> GetWindowInfoFromPoint(CGPoint point) {
  std::string windowTitle = "";
  std::string windowAppName = "";
  std::string windowUrl = "";

  // Get all windows and find the one containing the point
  CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  if (!windowList) return {windowTitle, windowAppName, windowUrl};

  CFIndex windowCount = CFArrayGetCount(windowList);

  for (CFIndex i = 0; i < windowCount; i++) {
    CFDictionaryRef windowDict = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
    if (!windowDict) continue;

    // Get window bounds
    CGRect windowBounds;
    CFDictionaryRef boundsDict = (CFDictionaryRef)CFDictionaryGetValue(windowDict, kCGWindowBounds);
    if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &windowBounds)) {
      continue;
    }

    // Check if point is within this window
    if (!CGRectContainsPoint(windowBounds, point)) {
      continue;
    }

    // Skip transparent windows
    CFNumberRef alphaRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowAlpha);
    if (alphaRef) {
      double alpha;
      if (CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha) && alpha == 0) {
        continue;
      }
    }

    // Skip tiny windows
    const double minWinSize = 50;
    if (windowBounds.size.width < minWinSize || windowBounds.size.height < minWinSize) {
      continue;
    }

    // Get window owner PID
    CFNumberRef ownerPIDRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerPID);
    if (!ownerPIDRef) continue;

    pid_t ownerPID;
    if (!CFNumberGetValue(ownerPIDRef, kCFNumberSInt32Type, &ownerPID)) {
      continue;
    }

    // Get running application
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPID];
    if (!app) continue;

    // Skip dock
    if ([[app bundleIdentifier] isEqualToString:@"com.apple.dock"]) {
      continue;
    }

    // Get window title
    CFStringRef titleRef = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowName);
    if (titleRef) {
      windowTitle = CFStringToStdString(titleRef);
    }

    // Get app name
    windowAppName = CFStringToStdString((CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerName));
    if (windowAppName.empty() && app.localizedName) {
      windowAppName = std::string([app.localizedName UTF8String]);
    }

    // Try to get browser URL
    if (app.bundleIdentifier) {
      std::string bundleId = std::string([app.bundleIdentifier UTF8String]);
      windowUrl = GetBrowserURL(bundleId);
    }

    CFRelease(windowList);
    return {windowTitle, windowAppName, windowUrl};
  }

  CFRelease(windowList);
  return {windowTitle, windowAppName, windowUrl};
}

// Helper function to get window information from active window
static std::tuple<std::string, std::string, std::string> GetActiveWindowInfo() {
  std::string windowTitle = "";
  std::string windowAppName = "";
  std::string windowUrl = "";

  // Get frontmost application
  NSRunningApplication* frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
  if (!frontmostApp) {
    return {windowTitle, windowAppName, windowUrl};
  }

  pid_t frontmostPID = [frontmostApp processIdentifier];

  // Get all windows and find the frontmost app's window
  CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  if (!windowList) {
    return {windowTitle, windowAppName, windowUrl};
  }

  CFIndex windowCount = CFArrayGetCount(windowList);

  for (CFIndex i = 0; i < windowCount; i++) {
    CFDictionaryRef windowDict = (CFDictionaryRef)CFArrayGetValueAtIndex(windowList, i);
    if (!windowDict) continue;

    // Get window owner PID
    CFNumberRef ownerPIDRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerPID);
    if (!ownerPIDRef) continue;

    pid_t ownerPID;
    if (!CFNumberGetValue(ownerPIDRef, kCFNumberSInt32Type, &ownerPID)) {
      continue;
    }

    // Only process windows from the frontmost app
    if (ownerPID != frontmostPID) {
      continue;
    }

    // Get window bounds
    CGRect windowBounds;
    CFDictionaryRef boundsDict = (CFDictionaryRef)CFDictionaryGetValue(windowDict, kCGWindowBounds);
    if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &windowBounds)) {
      continue;
    }

    // Skip transparent windows
    CFNumberRef alphaRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowAlpha);
    if (alphaRef) {
      double alpha;
      if (CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha) && alpha == 0) {
        continue;
      }
    }

    // Skip tiny windows
    const double minWinSize = 50;
    if (windowBounds.size.width < minWinSize || windowBounds.size.height < minWinSize) {
      continue;
    }

    // Get running application
    NSRunningApplication* app = [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPID];
    if (!app) continue;

    // Skip dock
    if ([[app bundleIdentifier] isEqualToString:@"com.apple.dock"]) {
      continue;
    }

    // Get window title
    CFStringRef titleRef = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowName);
    if (titleRef) {
      windowTitle = CFStringToStdString(titleRef);
    }

    // Get app name
    windowAppName = CFStringToStdString((CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerName));
    if (windowAppName.empty() && app.localizedName) {
      windowAppName = std::string([app.localizedName UTF8String]);
    }

    // Try to get browser URL
    if (app.bundleIdentifier) {
      std::string bundleId = std::string([app.bundleIdentifier UTF8String]);
      windowUrl = GetBrowserURL(bundleId);
    }

    CFRelease(windowList);
    return {windowTitle, windowAppName, windowUrl};
  }

  CFRelease(windowList);
  return {windowTitle, windowAppName, windowUrl};
}

static const char* TypeToName(CGEventType t) {
  switch (t) {
    case kCGEventKeyDown:
      return "keypress";
    case kCGEventLeftMouseDown:
    case kCGEventRightMouseDown:
    case kCGEventOtherMouseDown:
      return "mousedown";
    case kCGEventLeftMouseUp:
    case kCGEventRightMouseUp:
    case kCGEventOtherMouseUp:
      return "mouseup";
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged:
      return "mousedrag";
    default:
      return "unknown";
  }
}

static CGEventRef Callback(CGEventTapProxy, CGEventType type, CGEventRef event, void*) {
  if (!running.load()) return event;

  CGPoint p = CGEventGetLocation(event);
  int64_t btn = (int64_t)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
  CGEventFlags flags = CGEventGetFlags(event);
  bool metaKey = (flags & kCGEventFlagMaskCommand) != 0;
  bool altKey = (flags & kCGEventFlagMaskAlternate) != 0;
  bool shiftKey = (flags & kCGEventFlagMaskShift) != 0;
  bool ctrlKey = (flags & kCGEventFlagMaskControl) != 0;

  // Extract key character for keypress (key down) events using the current keyboard layout
  int32_t keychar = 0;
  std::string key = "";
  if (type == kCGEventKeyDown) {
    UniChar buffer[4] = {0};
    UniCharCount length = 0;
    CGEventKeyboardGetUnicodeString(event, 4, &length, buffer);
    if (length > 0) {
      keychar = (int32_t)buffer[0];
      // Convert Unicode character to UTF-8 string
      CFStringRef cfString = CFStringCreateWithCharacters(kCFAllocatorDefault, buffer, length);
      if (cfString) {
        CFIndex maxSize = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);
        char* utf8Buffer = new char[maxSize + 1];
        if (CFStringGetCString(cfString, utf8Buffer, maxSize + 1, kCFStringEncodingUTF8)) {
          key = std::string(utf8Buffer);
        }
        delete[] utf8Buffer;
        CFRelease(cfString);
      }
    }
  }

  // Determine click count from event (macOS provides this)
  int64_t clicks = (int64_t)CGEventGetIntegerValueField(event, kCGMouseEventClickState);

  tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", TypeToName(type));
    if (type == kCGEventKeyDown) {
      obj.Set("keychar", keychar);
      obj.Set("key", key);
    } else {
      obj.Set("x", p.x);
      obj.Set("y", p.y);
      obj.Set("button", btn);
      obj.Set("clicks", clicks);
    }
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);

    // Get window information based on event type
    std::string windowTitle, windowAppName, windowUrl;
    if (type == kCGEventKeyDown) {
      auto windowInfo = GetActiveWindowInfo();
      windowTitle = std::get<0>(windowInfo);
      windowAppName = std::get<1>(windowInfo);
      windowUrl = std::get<2>(windowInfo);
    } else {
      auto windowInfo = GetWindowInfoFromPoint(p);
      windowTitle = std::get<0>(windowInfo);
      windowAppName = std::get<1>(windowInfo);
      windowUrl = std::get<2>(windowInfo);
    }

    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
    obj.Set("windowUrl", windowUrl);
    cb.Call({ obj });
  });

  return event; // don’t swallow
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
    tsfn = Napi::ThreadSafeFunction::New(env, info[0].As<Napi::Function>(), "mousecb", 0, 1);
  }

  Napi::Value Start(const Napi::CallbackInfo& info) {
    if (running.exchange(true)) return info.Env().Undefined();

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
      CGEventMask mask =
        CGEventMaskBit(kCGEventKeyDown)          |
        CGEventMaskBit(kCGEventLeftMouseDown)   |
        CGEventMaskBit(kCGEventLeftMouseUp)     |
        CGEventMaskBit(kCGEventRightMouseDown)  |
        CGEventMaskBit(kCGEventRightMouseUp)    |
        CGEventMaskBit(kCGEventOtherMouseDown)  |
        CGEventMaskBit(kCGEventOtherMouseUp)    |
        CGEventMaskBit(kCGEventLeftMouseDragged)|
        CGEventMaskBit(kCGEventRightMouseDragged)|
        CGEventMaskBit(kCGEventOtherMouseDragged);

      tap = CGEventTapCreate(kCGSessionEventTap,
                             kCGHeadInsertEventTap,
                             kCGEventTapOptionListenOnly,
                             mask,
                             Callback,
                             nullptr);

      if (!tap) {
        running.store(false);
        return;
      }

      runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
      CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
      CGEventTapEnable(tap, true);
      CFRunLoopRun(); // blocks until stopped
    });

    return info.Env().Undefined();
  }

  Napi::Value Stop(const Napi::CallbackInfo& info) {
    if (!running.exchange(false)) return info.Env().Undefined();
    if (tap) {
      CGEventTapEnable(tap, false);
      CFRunLoopSourceInvalidate(runLoopSource);
      CFRelease(runLoopSource);
      CFRelease(tap);
      runLoopSource = nullptr;
      tap = nullptr;
    }
    if (tsfn) tsfn.Release();
    return info.Env().Undefined();
  }
};

Napi::Object InitAll(Napi::Env env, Napi::Object exports) {
  return Hook::Init(env, exports);
}

NODE_API_MODULE(mouse_hook, InitAll)
