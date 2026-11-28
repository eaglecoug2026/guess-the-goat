import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validate } from '../../tools/validate-categories.mjs';

const all = JSON.parse(readFileSync(new URL('../../content/categories.json', import.meta.url), 'utf8'));
const one = () => structuredClone(all.find(c => c.id === 'nfl-quarterback'));
const errs = c => validate([c]).errors;

test('content/categories.json passes: 68 categories, unique ids, every one grouped', () => {
  assert.equal(all.length, 68);
  for (const c of all) assert.ok(c.group && c.sub, c.id + ' has a group and sub');
  // D-37: each family has exactly one "All" list, and no group is called NFL anymore.
  const fams = [...new Set(all.filter(c => c.family).map(c => c.family))].sort();
  assert.deepEqual(fams, ['MLB player', 'NBA player', 'NFL player']);
  for (const f of fams) assert.equal(all.filter(c => c.family === f && c.sub === 'All').length, 1, f + ' has one All');
  assert.equal(all.filter(c => c.group === 'NFL').length, 0);
  assert.deepEqual(validate(all).errors, []);
});

test('family must be null or 1-30 characters', () => {
  const c = one(); c.family = 'x'.repeat(31);
  assert.match(errs(c).join(), /family must be/);
  c.family = 'NFL player'; assert.deepEqual(errs(c), []);
  c.family = null; assert.deepEqual(errs(c), []);
});

test('rejects a clue with a word from the answer, accents ignored', () => {
  const c = one(); c.clues['Joe Montana'][0] = 'MONTANA played in San Francisco.';
  assert.match(errs(c).join(), /contains "montana"/);
  const s = structuredClone(all.find(x => x.id === 'soccer-player')); s.clues['Pelé'][0] = 'Pele was Brazilian.';
  assert.match(errs(s).join(), /contains "pele"/);
});

test('rejects bad percents, wrong clue keys, long clues and repeat ids', () => {
  let c = one(); c.opts[3][1] = 50; assert.match(errs(c).join(), /higher than the one above/);
  c = one(); c.opts[12][1] = 1; assert.match(errs(c).join(), /must be 0/);
  c = one(); c.opts[0][1] = 80; assert.match(errs(c).join(), /add up to/);
  c = one(); delete c.clues['Tom Brady']; assert.match(errs(c).join(), /missing clues for "Tom Brady"/);
  c = one(); c.clues['Tom Brady'][0] = 'x'.repeat(91); assert.match(errs(c).join(), /max 90/);
  c = one(); c.opts.pop(); assert.match(errs(c).join(), /exactly 16/);
  assert.match(validate([one(), one()]).errors.join(), /id repeats/);
});
