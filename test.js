const { MouseHook } = require("./dist/index.js");

const mouseHook = new MouseHook();
mouseHook.start();

mouseHook.on("mousedown", (evt) => {
  console.log('mousedown:', evt);
});

mouseHook.on("mouseup", (evt) => {
  console.log('mouseup:', evt);
});

mouseHook.on("mousedrag", (evt) => {
  console.log('mousedrag:', evt);
});

setTimeout(() => {
  mouseHook.stop();
}, 20000);

mouseHook.on("keypress", (evt) => {
  console.log('keypress:', evt);
});
