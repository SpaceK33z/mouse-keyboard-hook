#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <atomic>
#include <thread>
#include <napi.h>

static CFMachPortRef tap = nullptr;
static CFRunLoopSourceRef runLoopSource = nullptr;
static std::atomic<bool> running{false};
static Napi::ThreadSafeFunction tsfn;

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

      if (!tap) { running.store(false); return; }

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
