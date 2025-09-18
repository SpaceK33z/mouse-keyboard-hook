export type MouseEvent = {
  type: "mousedown" | "mouseup" | "mousedrag";
  x: number;
  y: number;
  button: number; // 0 = left, 1 = right, 2 = middle mouse
  clicks: number; // 1 = single, 2 = double, 3 = triple
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
  windowTitle: string;
  windowAppName: string;
  windowUrl?: string; // only set for macOS
};

export type KeypressEvent = {
  type: "keypress";
  keychar: number; // numeric codepoint; e.g. 9=Tab, 13=Enter
  key: string; // string representation of the key pressed
  x: number; // current mouse x position
  y: number; // current mouse y position
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
  windowTitle: string;
  windowAppName: string;
  windowUrl?: string; // only set for macOS
};

export type MouseHookEventMap = {
  mousedown: [MouseEvent];
  mouseup: [MouseEvent];
  mousedrag: [MouseEvent];
  keypress: [KeypressEvent];
};
