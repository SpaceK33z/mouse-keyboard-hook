import { EventEmitter } from 'node:events';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const require = createRequire(import.meta.url);
const addon = require(join(__dirname, 'build/Release/mouse_hook.node'));

export class MouseHook extends EventEmitter {
  #hook;
  constructor() {
    super();
    this.#hook = new addon.Hook((evt) => this.emit('event', evt));
  }
  start() { this.#hook.start(); }
  stop() { this.#hook.stop(); }
}