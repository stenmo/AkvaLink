// Regenerates app/index.html + app/src/page.js from ../web/index.html so the
// native app reuses the exact landing-page UI (web/ stays the single source of
// truth). Every inline (attribute-less) <script> block — the page logic — is
// moved into src/page.js, and a single module entry (src/main.js) is injected,
// which imports the native BLE shim first, then page.js.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(here, '..');
const WEB = resolve(APP, '..', 'web');

const html = await readFile(resolve(WEB, 'index.html'), 'utf8');

// Pull out every inline <script>…</script> (no attributes) in document order.
// Leaves <link>, <style>, and any attributed scripts untouched.
const scripts = [];
const stripped = html.replace(/<script>([\s\S]*?)<\/script>/g, (_match, body) => {
  scripts.push(body.trim());
  return '';
});
if (scripts.length === 0) {
  throw new Error('build-web: no inline <script> blocks found in web/index.html');
}

const appHtml = stripped.replace(
  /<\/body>/i,
  '  <script type="module" src="./src/main.js"></script>\n</body>'
);

const header =
  '// GENERATED from ../web/index.html by scripts/build-web.mjs — do not edit.\n' +
  '// Regenerate with `npm run sync-web` (also runs before dev/build).\n\n';

await mkdir(resolve(APP, 'src'), { recursive: true });
await writeFile(resolve(APP, 'src', 'page.js'), header + scripts.join('\n\n') + '\n', 'utf8');
await writeFile(resolve(APP, 'index.html'), appHtml, 'utf8');

console.log(
  `build-web: wrote index.html + src/page.js (${scripts.length} inline script block(s)) from web/index.html`
);
