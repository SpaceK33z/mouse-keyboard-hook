export type MouseEvent = {
  type: "mousedown" | "mouseup" | "mousedrag";
  x: number;
  y: number;
  button: number; // 0 = left, 1 = right, 2 = middle mouse
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
  windowTitle: string;
  windowAppName: string;
  windowUrl: string;
};

export type KeypressEvent = {
  type: "keypress";
  keychar: number; // numeric codepoint; e.g. 9=Tab, 13=Enter
  key: string; // string representation of the key pressed
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  ctrlKey: boolean;
  windowTitle: string;
  windowAppName: string;
  windowUrl: string;
};

export type MouseHookEventMap = {
  mousedown: [MouseEvent];
  mouseup: [MouseEvent];
  mousedrag: [MouseEvent];
  keypress: [KeypressEvent];
};
