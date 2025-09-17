const { EventEmitter } = require('node:events');
const { join } = require('node:path');

const addon = require(join(__dirname, 'build/Release/mouse_hook.node'));

class MouseHook extends EventEmitter {
  #hook;
  constructor() {
    super();
    this.#hook = new addon.Hook((evt) => this.emit('event', evt));
  }
  start() { this.#hook.start(); }
  stop() { this.#hook.stop(); }
}

module.exports = { MouseHook };