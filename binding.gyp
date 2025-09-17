{
  "targets": [
    {
      "target_name": "mouse_hook",
      "sources": ["src/mouse_hook_mac.mm"],
      "cflags!": ["-fno-exceptions"],
      "cflags_cc!": ["-fno-exceptions"],
      "xcode_settings": {
        "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
        "OTHER_LDFLAGS": ["-framework", "CoreGraphics", "-framework", "ApplicationServices"]
      },
      "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
      "defines": ["NAPI_CPP_EXCEPTIONS"]
    }
  ]
}