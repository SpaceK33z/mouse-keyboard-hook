## mouse-keyboard-hook

A Node.js native addon to track mouse and keyboard events on macOS and Windows. Linux not supported!

This was developed as an alternative to the various iohook packages that there are. This package is way simpler and does not have any external dependencies.

Features;

* Track mousedown / mouseup / mousedrag
  * x,y coordinates
  * button that was pressed (1 = left, 2 = right, 3 = middle)
  * alt / shift / meta key pressed during the event
  * window title where the event occurred
* Track keypress
  * `keychar`, e.g. 9 = Tab, 13 = Enter
  * `key`, e.g. "A"
  * alt / shift / meta key pressed during the event
  * window title of the active window
  * x,y coordinates (for cursor position)

### Install

```bash
pnpm install @spacek33z/mouse-hook
# or
npm install @spacek33z/mouse-hook
```

### Prerequisites

This project compiles a native module during install/build using `node-gyp`. Make sure the toolchain is ready:

- **Node.js**: v20+
- **Python 3** (required by `node-gyp`)
- **node-gyp** installed globally (`npm i -g node-gyp`)
- For macOS:
  - **Xcode Command Line Tools** (`xcode-select --install`)
- For Windows:
 - **Visual Studio Build Tools** (C++ build tools)

### Usage

```js
import MouseHook from '@spacek33z/mouse-hook';

const mouseHook = new MouseHook();
mouseHook.start();

mouseHook.on('mousedown', (evt) => {
  console.log('mousedown:', evt);
  console.log('Window:', evt.windowTitle);
});

mouseHook.on('keypress', (evt) => {
  console.log('keypress:', evt);
  console.log('Window:', evt.windowTitle);
});

// At some point later:
mouseHook.stop();
```

### Development

If you want to work on this package, first run:

```bash
pnpm install
pnpm build
```

Then you can launch this test script to see if everything works:

```bash
node test.js
```

### Troubleshooting `node-gyp`

- **No Python found**: Install Python 3 and run `npm config set python "$(which python3)"`
- **No Xcode or CLT**: Run `xcode-select --install`
- **`binding.gyp` not found**: Run commands from the project root (where `binding.gyp` is)
- **Arch mismatch on Apple Silicon**: Use a native ARM64 shell or `arch -arm64 pnpm run build`
- **Windows cannot find `cl.exe`**: Open a "x64 Native Tools for VS" shell or ensure VS Build Tools installed
- **`User32.lib` not found (Windows)**: Ensure Windows SDK is installed via Build Tools
- **Permission/Xcode license**: `sudo xcodebuild -license accept`
