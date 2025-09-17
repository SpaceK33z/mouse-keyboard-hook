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
    case kCGEventLeftMouseDown: return "leftdown";
    case kCGEventLeftMouseUp: return "leftup";
    case kCGEventRightMouseDown: return "rightdown";
    case kCGEventRightMouseUp: return "rightup";
    case kCGEventOtherMouseDown: return "otherdown";
    case kCGEventOtherMouseUp: return "otherup";
    case kCGEventMouseMoved: return "move";
    case kCGEventLeftMouseDragged: return "leftdrag";
    case kCGEventRightMouseDragged: return "rightdrag";
    case kCGEventOtherMouseDragged: return "otherdrag";
    case kCGEventScrollWheel: return "scroll";
    default: return "unknown";
  }
}

static CGEventRef Callback(CGEventTapProxy, CGEventType type, CGEventRef event, void*) {
  if (!running.load()) return event;

  CGPoint p = CGEventGetLocation(event);
  double deltaX = 0, deltaY = 0;
  int64_t btn = (int64_t)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);

  if (type == kCGEventScrollWheel) {
    deltaY = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis1);
    deltaX = CGEventGetDoubleValueField(event, kCGScrollWheelEventDeltaAxis2);
  }

  tsfn.BlockingCall([=](Napi::Env env, Napi::Function cb) {
    Napi::Object obj = Napi::Object::New(env);
    obj.Set("type", TypeToName(type));
    obj.Set("x", p.x);
    obj.Set("y", p.y);
    obj.Set("button", btn);
    obj.Set("deltaX", deltaX);
    obj.Set("deltaY", deltaY);
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
        CGEventMaskBit(kCGEventLeftMouseDown)   |
        CGEventMaskBit(kCGEventLeftMouseUp)     |
        CGEventMaskBit(kCGEventRightMouseDown)  |
        CGEventMaskBit(kCGEventRightMouseUp)    |
        CGEventMaskBit(kCGEventOtherMouseDown)  |
        CGEventMaskBit(kCGEventOtherMouseUp)    |
        CGEventMaskBit(kCGEventMouseMoved)      |
        CGEventMaskBit(kCGEventLeftMouseDragged)|
        CGEventMaskBit(kCGEventRightMouseDragged)|
        CGEventMaskBit(kCGEventOtherMouseDragged)|
        CGEventMaskBit(kCGEventScrollWheel);

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