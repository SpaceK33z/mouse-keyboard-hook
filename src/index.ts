import { EventEmitter } from "node:events";
import { join } from "node:path";
import { MouseHookEventMap } from "./types";

const addon = require(join(__dirname, "../build/Release/mouse_hook.node"));

class MouseHook extends EventEmitter<MouseHookEventMap> {
  #hook;
  constructor() {
    super();
    this.#hook = new addon.Hook((evt: any) => this.emit(evt.type, evt as any));
  }
  start() {
    this.#hook.start();
  }
  stop() {
    this.#hook.stop();
  }
}

module.exports = { MouseHook };
