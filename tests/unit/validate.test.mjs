import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { validate } from '../../tools/validate-categories.mjs';

const all = JSON.parse(readFileSync(new URL('../../content/categories.json', import.meta.url), 'utf8'));
const one = () => structuredClone(all.find(c => c.id === 'nfl-quarterback'));
const errs = c => validate([c]).errors;

test('content/categories.json passes: 48 categories, unique ids', () => {
  assert.equal(all.length, 48);
  assert.deepEqual(validate(all).errors, []);
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
