// Loads GoatCore straight out of index.html, so the tests exercise the exact code the page runs.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const html = readFileSync(new URL('../../index.html', import.meta.url), 'utf8');
const m = html.match(/<script id="goat-core">([\s\S]*?)<\/script>/);
if (!m) throw new Error('goat-core script not found in index.html');
const ctx = vm.createContext({ crypto: globalThis.crypto, Uint8Array });
vm.runInContext(m[1] + '\n;this.GoatCore = GoatCore;', ctx);
export const G = ctx.GoatCore;
export const bundled = JSON.parse(html.match(/<script type="application\/json" id="bundled-catalog">([\s\S]*?)<\/script>/)[1]);
