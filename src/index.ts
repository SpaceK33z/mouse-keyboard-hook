import { EventEmitter } from "node:events";
import { join } from "node:path";
import { MouseHookEventMap } from "./types.js";

const addon = require(join(__dirname, "../build/Release/mouse_hook.node"));

class MouseHook extends EventEmitter<MouseHookEventMap> {
  #hook;
  constructor() {
    super();
    this.#hook = new addon.Hook((evt: any) => this.emit(evt.type, evt));
  }
  start() {
    this.#hook.start();
  }
  stop() {
    this.#hook.stop();
  }
}

export { MouseHook };
