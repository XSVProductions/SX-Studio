{{flutter_js}}
{{flutter_build_config}}
// The page is built twice, as JavaScript and as WebAssembly, and the loader
// picks. WebAssembly builds a screen about twice as fast. Flutter offers it
// to Chrome only, so this turns it on for Safari (every browser on an iPhone
// or iPad) and Firefox too. A browser too old for it gets the JavaScript page
// by itself.
//
// Each WebAssembly start is counted until it draws its first frame. After two
// that never did, this browser takes the JavaScript page, which is what every
// browser ran before. So a phone that can't run the faster page shows the
// slower one, not a blank screen.
(() => {
  const key = 'sx_wasm_fails';
  let fails = 0;
  try {
    fails = Number(localStorage.getItem(key) || 0);
    if (fails < 2) {
      localStorage.setItem(key, String(fails + 1));
      window.addEventListener('flutter-first-frame', () => localStorage.removeItem(key), { once: true });
    }
  } catch (e) {
    // no storage (a private tab): try WebAssembly every time
  }
  const wasm = fails < 2;
  _flutter.loader.load({
    config: { wasmAllowList: { blink: wasm, webkit: wasm, gecko: wasm } },
  });
})();
