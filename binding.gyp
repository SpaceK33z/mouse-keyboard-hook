{
  "targets": [
    {
      "target_name": "mouse_hook",
      "include_dirs": ["<!@(node -p \"require('node-addon-api').include\")"],
      "defines": ["NAPI_CPP_EXCEPTIONS"],
      "cflags!": ["-fno-exceptions"],
      "cflags_cc!": ["-fno-exceptions"],
      "conditions": [
        ["OS=='mac'", {
          "sources": ["src/mouse_hook_mac.mm"],
          "xcode_settings": {
            "GCC_ENABLE_CPP_EXCEPTIONS": "YES",
            "OTHER_LDFLAGS": ["-framework", "CoreGraphics", "-framework", "ApplicationServices", "-framework", "AppKit"]
          }
        }],
        ["OS=='win'", {
          "sources": ["src/mouse_hook_win.cpp"],
          "msvs_settings": {
            "VCCLCompilerTool": { "ExceptionHandling": 1 },
            "VCLinkerTool": {
              "AdditionalDependencies": ["User32.lib"]
            }
          },
          "libraries": ["User32.lib"]
        }]
      ]
    }
  ]
}
