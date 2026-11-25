import test from 'node:test';
import assert from 'node:assert/strict';
import { G, bundled } from './load-core.mjs';

// Ten estimated contenders (sum 1.00) plus six at 0, as the content format requires.
const OPTS = [
  ['A', .30], ['B', .20], ['C', .12], ['D', .10], ['E', .08], ['F', .07], ['G', .05], ['H', .04], ['I', .02], ['J', .02],
  ['K', 0], ['L', 0], ['M', 0], ['N', 0], ['O', 0], ['P', 0]
].map(([name, est]) => ({ name, est }));
const near = (a, b) => Math.abs(a - b) < 1e-6;

test('blended share follows b = (v + k·e) / (V + k) for V = 0, 1, 150, 499, 500, 5000', () => {
  for (const V of [0, 1, 150, 499, 500, 5000]) {
    // Spread V votes: 40% to K (an out-of-top-10 name), 60% to A, so the order can change.
    const counts = V ? { K: Math.round(V * 0.4), A: V - Math.round(V * 0.4) } : {};
    const r = G.blendRanking(OPTS, counts, 100);
    assert.equal(r.total_votes, V);
    for (const e of r.ranking) {
      const v = counts[e.name] || 0, est = OPTS.find(o => o.name === e.name).est;
      assert.ok(near(e.blended, (v + 100 * est) / (V + 100)), `V=${V} ${e.name}`);
    }
    const shares = r.ranking.map(e => e.blended);
    assert.deepEqual(shares, [...shares].sort((a, b) => b - a), 'sorted by blended share');
    assert.deepEqual(r.ranking.map(e => e.rank), r.ranking.map((_, i) => i + 1));
    const sum = r.ranking.reduce((t, e) => t + e.blended, 0);
    assert.ok(Math.abs(sum - 1) < 1e-4, `shares sum to 1 at V=${V}`);
  }
});

test('V = 0 ranks purely by estimate; at V = 5000 votes dominate', () => {
  assert.deepEqual(G.blendRanking(OPTS, {}, 100).ranking.slice(0, 3).map(e => e.name), ['A', 'B', 'C']);
  const r = G.blendRanking(OPTS, { K: 2000, A: 3000 }, 100);
  assert.deepEqual(r.ranking.slice(0, 2).map(e => e.name), ['A', 'K']);
  assert.equal(G.tierOf(r.ranking[1]), 1, 'K climbed into Hot from outside the top 10');
});

test('ties break by estimate, then by name in code-point order', () => {
  const r = G.blendRanking([{ name: 'b', est: .1 }, { name: 'a', est: .1 }, { name: 'Z', est: .1 }, { name: 'c', est: .2 }], { c: 0 }, 100);
  assert.deepEqual(r.ranking.map(e => e.name), ['c', 'Z', 'a', 'b']);
  const t = G.blendRanking([{ name: 'x', est: .2 }, { name: 'y', est: .1 }], { y: 10 }, 100);
  // x: (0+20)/110, y: (10+10)/110 -> equal b, x wins on estimate
  assert.deepEqual(t.ranking.map(e => e.name), ['x', 'y']);
});

test('disclosure tier and label by total votes', () => {
  const cases = [[0, 'estimated', 'Estimated ranking'], [1, 'blended', 'Blended community ranking · 1 vote'],
    [150, 'blended', 'Blended community ranking · 150 votes'], [499, 'blended', 'Blended community ranking · 499 votes'],
    [500, 'community', 'Community ranking · 500 votes (includes estimated weighting)'],
    [5000, 'community', 'Community ranking · 5,000 votes (includes estimated weighting)']];
  for (const [V, tier, label] of cases) {
    assert.equal(G.tierName(V, [1, 500]), tier, `tier V=${V}`);
    assert.equal(G.disclosure(tier, V), label, `label V=${V}`);
  }
});

test('guess tiers: #1 GOAT, #2-3 Hot, #4-6 Warm, #7-10 Cold, else Not top 10', () => {
  const r = G.blendRanking(OPTS, {}, 100).ranking;
  assert.deepEqual(r.map(G.tierOf), [0, 1, 1, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4]);
  assert.equal(G.badge(r[1]), '#2 · Hot · 20%');
  assert.equal(G.badge(r[0]), '#1 · GOAT · 30%');
  assert.equal(G.badge(r[12]), '#13 · Not top 10');
  assert.equal(G.tierOf({ rank: 5, blended: 0 }), 4, 'a zero share is never top 10');
});

test('Hot Take Score', () => {
  assert.equal(G.hotTake(.3, .3), 0);
  assert.equal(G.hotTake(.2, .3), 33);
  assert.equal(G.hotTake(.02, .3), 93);
  assert.equal(G.hotTake(0, .3), 100);
  assert.deepEqual([0, 1, 40, 41, 75, 76, 99, 100].map(G.hotLabel),
    ['Consensus king', 'Mild take', 'Mild take', 'Spicy take', 'Spicy take', 'Hot take', 'Hot take', 'Certified contrarian']);
});

test('puzzle number counts local calendar days, safe across US DST changes', () => {
  assert.equal(G.puzzleNo('2027-01-01', '2027-01-01'), 1);
  assert.equal(G.puzzleNo('2027-01-02', '2027-01-01'), 2);
  // Spring forward 2027-03-14, fall back 2027-11-07 (US).
  const days = ['2027-03-13', '2027-03-14', '2027-03-15', '2027-11-06', '2027-11-07', '2027-11-08'];
  const nos = days.map(d => G.puzzleNo(d, '2027-01-01'));
  assert.deepEqual(nos, [72, 73, 74, 310, 311, 312]);
  assert.equal(G.puzzleNo('2027-01-01', null), null);
  // Local midnights across the change, as a browser in New York sees them.
  const ny = (y, m, d, h) => new Date(Date.UTC(y, m - 1, d, h));
  assert.equal(G.addDays('2027-03-13', 1), '2027-03-14');
  assert.equal(G.addDays('2027-11-06', 1), '2027-11-07');
  assert.equal(G.daysBetween('2027-03-13', '2027-03-15'), 2);
  assert.equal(G.localDate(ny(2027, 3, 14, 12)).length, 10);
});

test('streak: a skipped day shows 0, consecutive wins add 1, excused days never break it', () => {
  let s = G.newStats();
  s = G.applyResult(s, '2027-01-01', true, 3, []);
  s = G.applyResult(s, '2027-01-02', true, 2, []);
  assert.equal(s.streak, 2);
  assert.equal(G.displayStreak(s, '2027-01-03', []), 2, 'yesterday won: streak alive');
  assert.equal(G.displayStreak(s, '2027-01-04', []), 0, 'skipped a day: shows 0 on load');
  assert.equal(G.displayStreak(s, '2027-01-04', ['2027-01-03']), 2, 'excused day: no break');
  s = G.applyResult(s, '2027-01-04', true, 1, ['2027-01-03']);
  assert.equal(s.streak, 3, 'win after an excused gap continues the streak');
  s = G.applyResult(s, '2027-01-06', true, 4, []);
  assert.equal(s.streak, 1, 'win after a real gap restarts at 1');
  s = G.applyResult(s, '2027-01-07', false, 5, []);
  assert.equal(s.streak, 0, 'a loss sets it to 0');
  assert.equal(s.maxStreak, 3);
  assert.equal(s.played, 5);
  assert.equal(s.wins, 4);
  assert.deepEqual({ ...s.dist }, { 1: 1, 2: 1, 3: 1, 4: 1, 5: 0, X: 1 });
  assert.deepEqual(G.applyResult(s, '2027-01-07', true, 1, []), s, 'a date is only recorded once');
});

test('old prototype stats migrate', () => {
  const s = G.normStats({ played: 4, wins: 3, streak: 2, last: '2027-01-02', lastWin: '2027-01-02' });
  assert.equal(s.lastPlayed, '2027-01-02');
  assert.equal(s.maxStreak, 2);
  assert.deepEqual({ ...s.dist }, { 1: 0, 2: 0, 3: 0, 4: 0, 5: 0, X: 0 });
});

test('share text: number, grid, score, ?r= link, and no answer name unless the pick is included', () => {
  const base = { no: 12, tiers: [3, 1, 0], won: true, score: 33, pick: 'Michael Jordan', url: 'https://x.test/goat/', ref: 'abcd1234' };
  const t = G.shareText({ ...base, includePick: false });
  assert.equal(t, "THE GOAT #12 🐐\n🟦🟧🟩 3/5 · Hot Take 33\nCan you find today's GOAT? https://x.test/goat/?r=abcd1234");
  assert.ok(!t.includes('Michael'));
  const p = G.shareText({ ...base, includePick: true });
  assert.ok(p.includes('\nMy GOAT: Michael Jordan\n'));
  const loss = G.shareText({ ...base, tiers: [4, 4, 3, 2, 1], won: false, score: null, includePick: false });
  assert.ok(loss.startsWith('THE GOAT #12 🐐\n⬛⬛🟦🟨🟧 X/5\n'));
});

test('ids: player UUIDs and 8-character referral codes', () => {
  assert.match(G.uuid(), /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  const r = G.refCode();
  assert.ok(G.isRef(r));
  assert.ok(!G.isRef('ABCD1234') && !G.isRef('abc') && !G.isRef('abcd1234x'));
});

test('bundled catalog is well formed and only used for practice', () => {
  assert.ok(bundled.length >= 12);
  for (const c of bundled) {
    assert.match(c.slug, /^[a-z0-9-]{2,40}$/);
    assert.equal(c.opts.length, 16);
    const top = G.blendRanking(c.opts, {}, 100).ranking[0].name;
    assert.equal(c.clues[top].length, 4, `${c.slug} has clues for its #1`);
  }
});
