import { EventEmitter } from "node:events";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { MouseHookEventMap } from "./types.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const require = createRequire(import.meta.url);

type MouseHookOptions = {
  nodeFile?: string;
  transparentWindowOwnerNames?: string[];
};

class MouseHook extends EventEmitter<MouseHookEventMap> {
  #hook;
  #transparentWindowOwnerNames: string[];

  constructor({ nodeFile, transparentWindowOwnerNames }: MouseHookOptions) {
    super();
    const addon = require(nodeFile ??
      join(__dirname, nodeFile ?? "../build/Release/mouse_hook.node"));
    this.#hook = new addon.Hook((evt: any) => this.emit(evt.type, evt));

    this.#transparentWindowOwnerNames = transparentWindowOwnerNames ?? [];
  }

  start() {
    this.#hook.start({
      transparentWindowOwnerNames: this.#transparentWindowOwnerNames,
    });
  }
  stop() {
    this.#hook.stop();
  }
}

export { MouseHook };
