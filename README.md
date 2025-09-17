## mouse-hook

A Node.js native addon to track mouse and keyboard events on macOS.

### Prerequisites (macOS)
This project compiles a native module during install/build using `node-gyp`. Make sure the toolchain is ready:

- **Node.js**: v20+ recommended
- **Xcode Command Line Tools** (provides `clang`, `make`)
- **Python 3** (required by `node-gyp`)
- **node-gyp** installed globally

Set up with:

```bash
# 1) Install Xcode Command Line Tools
xcode-select --install

# 2) Ensure Python 3 is available and set npm to use it
python3 --version
npm config set python "$(which python3)"

# 3) Install node-gyp globally
npm i -g node-gyp

# 4) (Sometimes required) Accept Xcode license
sudo xcodebuild -license accept
```

### Install

```bash
pnpm install @spacek33z/mouse-hook
# or
npm install @spacek33z/mouse-hook
```

### Usage

```js
const { MouseHook } = require('@spacek33z/mouse-hook');

const mouseHook = new MouseHook();
mouseHook.start();

mouseHook.on('mousedown', (evt) => {
  console.log('mousedown:', evt);
});
```

### Development

If you want to work on this package, first do:

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
- **Permission/Xcode license**: `sudo xcodebuild -license accept`

### Dev notes / TODO

- Make it work on Windows
