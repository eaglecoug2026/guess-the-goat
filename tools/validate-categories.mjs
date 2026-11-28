#!/usr/bin/env node
// Checks category content against HANDOFF §12 before it's imported.
// Usage: node tools/validate-categories.mjs [file.json ...]   (default: content/categories.json)
// Exits 1 on any error. Warnings are printed but don't fail.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const OPTS = 16, TOP = 10, CLUED = 3, CLUES = 4, CLUE_MAX = 90;
const ID_RE = /^[a-z0-9-]{2,40}$/;

const fold = s => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
const words = name => fold(name).split(/[^a-z0-9]+/).filter(w => w.length >= 4);

export function validate(cats) {
  const errors = [], warnings = [];
  if (!Array.isArray(cats)) return { errors: ['the file must be a JSON array of categories'], warnings };
  const ids = new Map();

  cats.forEach((c, i) => {
    const where = `#${i + 1} ${c && c.id ? c.id : '(no id)'}`;
    const err = m => errors.push(`${where}: ${m}`);
    const warn = m => warnings.push(`${where}: ${m}`);
    if (!c || typeof c !== 'object' || Array.isArray(c)) return err('not an object');

    const allowed = ['id', 'label', 'title', 'group', 'family', 'sub', 'kind', 'season', 'opts', 'clues', 'sources'];
    for (const k of Object.keys(c)) if (!allowed.includes(k)) err(`unknown field "${k}"`);

    if (typeof c.id !== 'string' || !ID_RE.test(c.id)) err('id must be 2-40 lowercase letters, numbers or hyphens');
    else if (ids.has(c.id)) err(`id repeats category #${ids.get(c.id)}`);
    else ids.set(c.id, i + 1);
    for (const k of ['label', 'title']) if (typeof c[k] !== 'string' || !c[k].trim()) err(`${k} is empty`);
    for (const k of ['group', 'sub']) if (typeof c[k] !== 'string' || !c[k].trim() || c[k].length > 30) err(`${k} must be 1-30 characters (the broad group, e.g. "NFL", and the short name in it, e.g. "QB")`);
    if (!(c.family === undefined || c.family === null || (typeof c.family === 'string' && c.family.trim() && c.family.length <= 30)))
      err('family must be null or 1-30 characters (the middle menu level, e.g. "NFL player" between "Sports" and "QB")');
    if (!['daily', 'vote'].includes(c.kind)) err('kind must be "daily" or "vote"');
    if (!(c.season === null || (typeof c.season === 'string' && c.season.trim()))) err('season must be null or a string');

    // contenders
    if (!Array.isArray(c.opts) || c.opts.length !== OPTS) { err(`needs exactly ${OPTS} contenders`); return; }
    const names = [], seen = new Map();
    let ok = true;
    c.opts.forEach((o, j) => {
      if (!Array.isArray(o) || o.length !== 2 || typeof o[0] !== 'string' || !o[0].trim() || typeof o[1] !== 'number') {
        ok = false; return err(`contender ${j + 1} must be ["name", percent]`);
      }
      const key = fold(o[0].trim());
      if (seen.has(key)) err(`"${o[0]}" repeats contender ${seen.get(key)}`); else seen.set(key, j + 1);
      names.push(o[0]);
    });
    if (!ok) return;
    const top = c.opts.slice(0, TOP), rest = c.opts.slice(TOP);
    top.forEach(([n, p], j) => {
      if (!Number.isInteger(p) || p <= 0) err(`"${n}" is in the top ${TOP}, so its percent must be a whole number above 0`);
      if (j > 0 && p > top[j - 1][1]) err(`"${n}" (${p}) is higher than the one above it (${top[j - 1][1]})`);
    });
    rest.forEach(([n, p]) => { if (p !== 0) err(`"${n}" is outside the top ${TOP}, so its percent must be 0`); });
    const sum = top.reduce((t, [, p]) => t + p, 0);
    if (sum < 80 || sum > 100) err(`top ${TOP} add up to ${sum}; must be 80-100`);
    if (top[CLUED - 1][1] === top[CLUED][1]) err(`#${CLUED} and #${CLUED + 1} tie at ${top[CLUED][1]}, so it's unclear which needs clues`);

    // clues
    const want = top.slice(0, CLUED).map(([n]) => n);
    if (!c.clues || typeof c.clues !== 'object' || Array.isArray(c.clues)) return err('clues must be an object');
    const keys = Object.keys(c.clues);
    for (const n of want) if (!keys.includes(n)) err(`missing clues for "${n}" (a top-${CLUED} contender; spelling must match exactly)`);
    for (const k of keys) if (!want.includes(k)) err(`clues for "${k}", who isn't in the top ${CLUED}`);
    for (const k of keys.filter(k => want.includes(k))) {
      const list = c.clues[k];
      if (!Array.isArray(list) || list.length !== CLUES) { err(`"${k}" needs exactly ${CLUES} clues`); continue; }
      const banned = [fold(k), ...words(k)];
      list.forEach((clue, j) => {
        const at = `"${k}" clue ${j + 1}`;
        if (typeof clue !== 'string' || !clue.trim()) return err(`${at} is empty`);
        if (clue.length > CLUE_MAX) err(`${at} is ${clue.length} characters; max ${CLUE_MAX}`);
        const f = fold(clue);
        const hit = banned.find(w => f.includes(w));
        if (hit) err(`${at} contains "${hit}" from the name: ${clue}`);
        for (const other of names) {
          if (other === k || fold(other).length < 4) continue;
          if (new RegExp(`(^|[^a-z0-9])${fold(other).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}($|[^a-z0-9])`).test(f)) warn(`${at} names another contender, "${other}"`);
        }
      });
    }

    // sources (optional)
    if (c.sources !== undefined) {
      if (!c.sources || typeof c.sources !== 'object' || Array.isArray(c.sources)) err('sources must be an object');
      else for (const [k, v] of Object.entries(c.sources)) {
        if (!names.includes(k)) err(`sources for "${k}", who isn't a contender`);
        if (!Array.isArray(v) || !v.length || v.some(u => typeof u !== 'string' || !/^https?:\/\//.test(u))) err(`sources for "${k}" must be a list of links`);
      }
      for (const n of want) if (!c.sources[n]) warn(`no sources for "${n}"`);
    } else warn('no sources');
  });
  return { errors, warnings, count: cats.length };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const files = process.argv.slice(2).length ? process.argv.slice(2) : ['content/categories.json'];
  let all = [];
  for (const f of files) {
    try { all = all.concat(JSON.parse(readFileSync(f, 'utf8'))); }
    catch (e) { console.error(`${f}: can't read as JSON: ${e.message}`); process.exit(1); }
  }
  const { errors, warnings } = validate(all);
  for (const w of warnings) console.log(`warning  ${w}`);
  for (const e of errors) console.log(`ERROR    ${e}`);
  console.log(`${all.length} categories, ${errors.length} errors, ${warnings.length} warnings`);
  process.exit(errors.length ? 1 : 0);
}
