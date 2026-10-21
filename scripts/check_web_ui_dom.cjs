/* Frontend runtime smoke test. Requires Node and jsdom, not a paid LLM API.
 * npm install --prefix tools/web-ui-test jsdom
 * NODE_PATH=tools/web-ui-test/node_modules node scripts/check_web_ui_dom.cjs http://127.0.0.1:8760
 * Uses a DOM emulator, not a full browser: module fetching/CSP are tested separately.
 */
const assert = require('node:assert/strict');
const { JSDOM, VirtualConsole } = require('jsdom');

(async () => {
  const base = process.argv[2] || 'http://127.0.0.1:8760';
  const response = await fetch(base);
  assert(response.ok);
  const html = await response.text();
  const errors = [];
  const console = new VirtualConsole();
  console.on('jsdomError', error => errors.push(error.message));
  const dom = new JSDOM(html, {
    url: base, runScripts: 'dangerously', pretendToBeVisual: true,
    virtualConsole: console,
  });
  try {
    const src = dom.window.document.querySelector('script[type="module"]').src;
    assert(src.includes('?v='), 'module must have a cache-busting content revision');
    const bundle = await fetch(src);
    assert(bundle.ok, 'module must be served');
    assert.match(bundle.headers.get('content-type'), /javascript/);
    dom.window.eval(await bundle.text());
    await new Promise(resolve => setTimeout(resolve, 300));
    const root = dom.window.document.getElementById('root');
    assert.match(root.textContent, /Movie Narrator/);
    assert(root.querySelector('input'), 'React task inputs must mount');
    assert.match(root.textContent, /Generate Narration Video/, 'task submission button must mount');
    assert(!root.querySelector('[data-ui-error]'), 'startup must not show an error');
    assert.deepEqual(errors, [], 'no frontend runtime errors');
    // Deliberately simulate a crash: users must see an actionable message,
    // and exception text must never be interpreted as markup.
    dom.window.dispatchEvent(new dom.window.ErrorEvent('error', {
      message: 'Injected startup failure <img src=x onerror=alert(1)>',
    }));
    assert.match(root.textContent, /Injected startup failure/);
    assert(root.querySelector('[data-ui-error]'));
    assert(!root.querySelector('img'));
    process.stdout.write('PASS: React form mounted; no runtime errors; visible, escaped crash reporting works.\n');
  } finally {
    dom.window.close();
  }
})().catch(error => { process.stderr.write(error.stack + '\n'); process.exitCode = 1; });
