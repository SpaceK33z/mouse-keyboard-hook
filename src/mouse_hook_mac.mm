#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <thread>
#include <napi.h>
#include <Cocoa/Cocoa.h>

static CFMachPortRef tap = nullptr;
static CFRunLoopSourceRef runLoopSource = nullptr;
static std::atomic<bool> running{false};
static Napi::ThreadSafeFunction tsfn;

// Helper function to get window title and app name from a point
static std::pair<std::string, std::string> GetWindowInfoFromPoint(CGPoint point) {
  // Get all windows and find the one containing the point
  CFArrayRef windowList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID);
  if (!windowList) return {"", ""};

  CFIndex windowCount = CFArrayGetCount(windowList);
  std::string title = "";
  std::string appName = "";

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
    if (CGRectContainsPoint(windowBounds, point)) {
      // Get window title
      CFStringRef titleRef = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowName);
      if (titleRef) {
        // Convert to UTF-8
        CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(titleRef), kCFStringEncodingUTF8);
        char* utf8Buffer = new char[maxSize + 1];

        if (CFStringGetCString(titleRef, utf8Buffer, maxSize + 1, kCFStringEncodingUTF8)) {
          title = std::string(utf8Buffer);
        }

        delete[] utf8Buffer;
      }

      // Get app name
      CFStringRef ownerNameRef = (CFStringRef)CFDictionaryGetValue(windowDict, kCGWindowOwnerName);
      if (ownerNameRef) {
        // Convert to UTF-8
        CFIndex maxSize = CFStringGetMaximumSizeForEncoding(CFStringGetLength(ownerNameRef), kCFStringEncodingUTF8);
        char* utf8Buffer = new char[maxSize + 1];

        if (CFStringGetCString(ownerNameRef, utf8Buffer, maxSize + 1, kCFStringEncodingUTF8)) {
          appName = std::string(utf8Buffer);
        }

        delete[] utf8Buffer;
      }

      // If we're getting "Dock" as the app name, it likely means we don't have proper permissions
      // Try to get more detailed window info
      if (appName == "Dock" || appName.empty()) {
        // Try alternative method using window layer
        CFNumberRef layerRef = (CFNumberRef)CFDictionaryGetValue(windowDict, kCGWindowLayer);
        if (layerRef) {
          int layer;
          if (CFNumberGetValue(layerRef, kCFNumberIntType, &layer)) {
            // Layer 0 is usually the desktop/dock, higher layers are actual windows
            if (layer == 0) {
              // This is likely the dock or desktop, try to find a better window
              continue;
            }
          }
        }
      }

      break;
    }
  }

  CFRelease(windowList);
  return {title, appName};
}

// Helper function to get window title and app name from active window
static std::pair<std::string, std::string> GetActiveWindowInfo() {
  NSWindow* activeWindow = [[NSApplication sharedApplication] keyWindow];
  if (!activeWindow) {
    // If no key window, try the main window
    activeWindow = [[NSApplication sharedApplication] mainWindow];
  }
  if (!activeWindow) return {"", ""};

  // Get the window title
  NSString* title = [activeWindow title];
  std::string titleStr = title ? std::string([title UTF8String]) : "";

  // Get the app name
  NSRunningApplication* app = [[NSWorkspace sharedWorkspace] frontmostApplication];
  std::string appName = "";
  if (app && app.localizedName) {
    appName = std::string([app.localizedName UTF8String]);
  }

  return {titleStr, appName};
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

  // Get window title and app name based on event type
  std::string windowTitle;
  std::string windowAppName;
  if (type == kCGEventKeyDown) {
    auto windowInfo = GetActiveWindowInfo();
    windowTitle = windowInfo.first;
    windowAppName = windowInfo.second;
  } else {
    auto windowInfo = GetWindowInfoFromPoint(p);
    windowTitle = windowInfo.first;
    windowAppName = windowInfo.second;
  }

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
    }
    obj.Set("metaKey", metaKey);
    obj.Set("altKey", altKey);
    obj.Set("shiftKey", shiftKey);
    obj.Set("ctrlKey", ctrlKey);
    obj.Set("windowTitle", windowTitle);
    obj.Set("windowAppName", windowAppName);
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
