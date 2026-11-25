import { test, expect } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';
import { createBackend, PASS } from './mock.mjs';

const NOON = d => new Date(`${d}T12:00:00-08:00`);
const TODAY = '2027-01-10'; // puzzle #10 with launch_date 2027-01-01

async function open(page, { time = NOON(TODAY), backend = createBackend(), storage = null, init = null, path = '/' } = {}) {
  const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  page.on('pageerror', e => errors.push(String(e)));
  await backend.install(page.context());
  await page.clock.install({ time });
  if (storage) await page.addInitScript(s => { if (!sessionStorage.getItem('__seeded')) { for (const [k, v] of Object.entries(s)) localStorage.setItem(k, JSON.stringify(v)); sessionStorage.setItem('__seeded', '1'); } }, storage);
  if (init) await page.addInitScript(init);
  await page.goto(path);
  return { backend, errors };
}
const chip = (page, name) => page.locator('#chips').getByRole('button', { name, exact: true });
async function guess(page, name) { await chip(page, name).click(); await expect(page.locator('#slots .slot.f .nm', { hasText: name }).first()).toBeVisible(); }
async function playToEnd(page, b, win, date = TODAY) {
  const wrong = b.wrongFor(date, 5);
  if (win) { await guess(page, wrong[0]); await guess(page, b.answerFor(date)); }
  else for (const n of wrong) await guess(page, n);
}
const noOverflow = page => page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth);
const realErrors = errors => errors.filter(e => !/ERR_INTERNET_DISCONNECTED|Failed to load resource/.test(e));

test('daily win: header, badges, stats, analytics, no console errors', async ({ page }) => {
  const { backend: b, errors } = await open(page);
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  await expect(page.locator('#disc')).toHaveText('Estimated ranking');
  const wrong = b.wrongFor(TODAY, 1)[0];
  await guess(page, wrong);
  await expect(page.locator('#slots .bd').first()).toHaveText(/^#2 · Hot · \d+%$/);
  await guess(page, b.answerFor(TODAY));
  await expect(page.locator('#slots .bd').nth(1)).toHaveText(/^#1 · GOAT · \d+%$/);
  await expect(page.locator('#side h2').first()).toHaveText('Found it in 2');
  await expect(page.locator('#sStreak')).toHaveText('1');
  await expect(page.locator('#sPlayed')).toHaveText('1');
  await expect(page.locator('#sWin')).toHaveText('100%');
  await expect.poll(() => b.eventsNamed('game_complete').length).toBe(1);
  expect(b.eventsNamed('game_complete')[0]).toMatchObject({ puzzle_no: 10, props: { won: true, guesses: 2 } });
  await expect.poll(() => b.eventsNamed('visit').length).toBe(1);
  expect(b.eventsNamed('game_start').length).toBe(1);
  expect(await noOverflow(page)).toBe(true);
  expect(errors).toEqual([]);
});

test('daily loss: five misses reveal the answer and reset the streak', async ({ page }) => {
  const { backend: b } = await open(page, { storage: { 'goat-stats': { played: 3, wins: 3, streak: 3, maxStreak: 3, lastWin: '2027-01-09', lastPlayed: '2027-01-09' } } });
  await expect(page.locator('#sStreak')).toHaveText('3');
  await playToEnd(page, b, false);
  await expect(page.locator('#side h2').first()).toHaveText(`The GOAT was ${b.answerFor(TODAY)}`);
  await expect(page.locator('#sStreak')).toHaveText('0');
  await expect(page.locator('#clues li.lock')).toHaveCount(0);
});

test('refresh mid-game restores guesses, clues and remaining guesses', async ({ page }) => {
  const { backend: b } = await open(page);
  const [w1, w2] = b.wrongFor(TODAY, 2);
  await guess(page, w1); await guess(page, w2);
  await page.reload();
  await expect(page.locator('#slots .slot.f')).toHaveCount(2);
  await expect(page.locator('#slots .slot.f .nm')).toHaveText([w1, w2]);
  await expect(page.locator('#clues li:not(.lock)')).toHaveCount(3);
  await expect(page.locator('#slots .slot:not(.f)')).toHaveCount(3);
  await expect(chip(page, w1)).toHaveCount(0);
});

test('personal pick is a vote: pick, change, fail and retry without duplicates', async ({ page }) => {
  const { backend: b } = await open(page);
  await playToEnd(page, b, true);
  const slug = b.puzzles[TODAY].slug, names = b.puzzles[TODAY].ranking.map(e => e.name);
  await page.locator('#side').getByRole('button', { name: names[3], exact: true }).click();
  await expect(page.locator('#side')).toContainText('Your pick counts toward the crowd ranking.');
  expect(Object.keys(b.votes[slug])).toHaveLength(1);
  const pid = Object.keys(b.votes[slug])[0];
  expect(b.votes[slug][pid]).toBe(names[3]);
  // change
  await page.getByRole('button', { name: 'Change pick' }).click();
  await page.locator('#side').getByRole('button', { name: names[0], exact: true }).click();
  await expect(page.locator('#side .big')).toHaveText('0');
  await expect.poll(() => b.votes[slug][pid]).toBe(names[0]);
  expect(Object.keys(b.votes[slug])).toHaveLength(1);
  // fail, then retry
  b.failNext.cast_vote = 1;
  await page.getByRole('button', { name: 'Change pick' }).click();
  await page.locator('#side').getByRole('button', { name: names[1], exact: true }).click();
  await expect(page.locator('#side [role=alert]')).toContainText('Your pick didn’t save.');
  expect(b.votes[slug][pid]).toBe(names[0]);
  await page.getByRole('button', { name: 'Retry' }).click();
  await expect(page.locator('#side')).toContainText('Your pick counts toward the crowd ranking.');
  expect(b.votes[slug]).toEqual({ [pid]: names[1] });
  await expect.poll(() => b.eventsNamed('pick_vote').map(e => e.props.changed)).toEqual([false, true, true]);
  expect(b.eventsNamed('vote_error')).toHaveLength(1);
});

for (const path of ['native', 'clipboard', 'manual']) {
  test(`share via ${path}: spoiler-free by default, pick only when toggled`, async ({ page }) => {
    const init = path === 'native'
      ? () => { window.__shared = []; Object.defineProperty(navigator, 'share', { configurable: true, value: d => { window.__shared.push(d.text); return Promise.resolve(); } }); }
      : path === 'clipboard'
        ? () => { window.__shared = []; Object.defineProperty(navigator, 'share', { configurable: true, value: undefined }); Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: t => { window.__shared.push(t); return Promise.resolve(); } } }); }
        : () => { window.__shared = []; Object.defineProperty(navigator, 'share', { configurable: true, value: undefined }); Object.defineProperty(navigator, 'clipboard', { configurable: true, value: undefined }); };
    const { backend: b } = await open(page, { init });
    await playToEnd(page, b, true);
    const answer = b.answerFor(TODAY), pick = b.puzzles[TODAY].ranking[2].name;
    await page.locator('#side').getByRole('button', { name: pick, exact: true }).click();
    await page.getByRole('button', { name: 'Share my result' }).click();
    const read = async () => path === 'manual' ? page.locator('#shareBox').inputValue() : (await page.evaluate(() => window.__shared)).at(-1);
    await expect.poll(read).toContain('THE GOAT #10');
    const text = await read();
    expect(text).toMatch(/^THE GOAT #10 🐐\n\S+ 2\/5 · Hot Take \d+\nCan you find today's GOAT\? http:\/\/127\.0\.0\.1:4173\/\?r=[a-z0-9]{8}$/);
    expect(text).not.toContain(answer);
    expect(text).not.toContain(pick);
    await page.getByLabel('Include my pick').check();
    await page.getByRole('button', { name: 'Share my result' }).click();
    await expect.poll(read).toContain(`My GOAT: ${pick}`);
    if (path === 'manual') await expect(page.locator('#shareBox')).toBeVisible();
    await expect.poll(() => b.eventsNamed('share').map(e => [e.props.method, e.props.spoiler])).toEqual([[path, false], [path, true]]);
  });
}

test('suggestions: send, list privately, duplicate error keeps the form', async ({ page }) => {
  const { backend: b } = await open(page);
  await page.getByLabel('Category').fill('Board game  night');
  await page.getByLabel(/Contenders/).fill('Catan, chess, Chess, Go');
  await page.getByRole('button', { name: 'Send suggestion' }).click();
  await expect(page.locator('#sMsg')).toContainText('is waiting for review');
  await expect(page.locator('#mine li')).toHaveCount(1);
  await expect(page.locator('#mine')).toContainText('Board game night');
  await expect(page.locator('#mine .st')).toHaveText('Waiting');
  expect(b.suggestions[0].opts).toEqual(['Catan', 'chess', 'Go']);
  await page.getByLabel('Category').fill('board game night');
  await page.getByRole('button', { name: 'Send suggestion' }).click();
  await expect(page.locator('#sMsg')).toHaveText('Someone already suggested that one.');
  await expect(page.getByLabel('Category')).toHaveValue('board game night');
  await expect(page.getByText('Up next from players')).toHaveCount(0);
});

test('owner: sign in, review, session expiry and sign out everywhere; nothing in localStorage', async ({ page }) => {
  const { backend: b } = await open(page);
  b.suggestions.push({ id: '00000000-0000-4000-8000-0000000000aa', name: 'Pasta shape', opts: ['Penne', 'Rigatoni', 'Fusilli', 'Farfalle'], voter: 'someone-else-1', status: 'pending', created_at: '2027-01-09T00:00:00Z' });
  await page.getByRole('button', { name: 'Owner sign-in' }).click();
  await page.getByLabel('Owner passphrase').fill('wrong');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#oMsg')).toHaveText('That passphrase didn’t work.');
  await page.getByLabel('Owner passphrase').fill(PASS);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#ownerPanel')).toBeVisible();
  const ls = await page.evaluate(() => JSON.stringify(localStorage));
  expect(ls).not.toContain(PASS);
  expect(ls).not.toContain('tok');
  expect(await page.evaluate(() => sessionStorage.getItem('goat-owner-token'))).toMatch(/^tok/);
  await expect(page.locator('#oQueue')).toContainText('Pasta shape');
  await page.locator('#oQueue').getByRole('button', { name: 'Add…' }).click();
  await page.locator('#oQueue').getByRole('button', { name: 'Add to game' }).click();
  await expect(page.locator('#ownerMsg')).toHaveText('Added to the game as a crowd vote.');
  await expect(page.locator('#cats')).toContainText('Pasta shape');
  // expire every session server-side; the next owner action returns to sign-in with a notice
  for (const x of Object.values(b.sessions)) x.expires = 0;
  await page.locator('#ownerPanel').getByRole('button', { name: 'Save correction' }).click();
  await expect(page.locator('#ownerPanel')).toBeHidden();
  await expect(page.locator('#oMsg')).toHaveText('Your owner session expired. Sign in again.');
  // sign in again, then revoke everywhere
  await page.getByLabel('Owner passphrase').fill(PASS);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#ownerPanel')).toBeVisible();
  page.once('dialog', d => d.accept());
  await page.getByRole('button', { name: 'Sign out everywhere' }).click();
  await expect(page.locator('#ownerPanel')).toBeHidden();
  expect(Object.values(b.sessions).every(x => x.revoked || x.expires === 0)).toBe(true);
  expect(await page.evaluate(() => sessionStorage.getItem('goat-owner-token'))).toBeNull();
});

test('offline with a cached daily: still playable', async ({ page }) => {
  const { backend: b, errors } = await open(page);
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  b.offline = true;
  await page.reload();
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  await guess(page, b.answerFor(TODAY));
  await expect(page.locator('#side h2').first()).toHaveText('Found it in 1');
  expect(realErrors(errors)).toEqual([]);
});

test('offline with no cached daily: notice, practice offer, never a substitute daily, excused date', async ({ page }) => {
  const b = createBackend(); b.offline = true;
  const { errors } = await open(page, { backend: b, storage: { 'goat-stats': { played: 1, wins: 1, streak: 4, maxStreak: 4, lastWin: '2027-01-09', lastPlayed: '2027-01-09' } } });
  await expect(page.locator('#notice')).toContainText('Today’s GOAT can’t load right now. We’ll keep trying.');
  await expect(page.locator('#tag')).not.toContainText('#');
  await expect(page.locator('#slots')).toBeHidden();
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('goat-excused')))).toEqual([TODAY]);
  await page.getByRole('button', { name: 'Play a practice round' }).click();
  await expect(page.locator('#tag')).toHaveText('Practice round');
  // the server comes back: the retry loop loads the real daily
  b.offline = false;
  await page.clock.fastForward(6000);
  await page.getByRole('button', { name: 'Today’s GOAT' }).first().click();
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  // the excused date never breaks the streak: tomorrow after missing today still shows 4
  await page.clock.setSystemTime(NOON('2027-01-11'));
  await page.reload();
  await expect(page.locator('#sStreak')).toHaveText('4');
  expect(realErrors(errors)).toEqual([]);
});

test('midnight rollover offers the new puzzle without interrupting a game in progress', async ({ page }) => {
  const { backend: b } = await open(page, { time: new Date('2027-01-10T23:58:00-08:00') });
  await guess(page, b.wrongFor(TODAY, 1)[0]);
  await page.clock.fastForward('03:00');
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  await expect(page.locator('#newday')).toBeVisible();
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  await expect(page.locator('#slots .slot.f')).toHaveCount(1);
  await page.getByRole('button', { name: 'Play it' }).click();
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #11 · Jan 11');
  await expect(page.locator('#slots .slot.f')).toHaveCount(0);
});

test('midnight rollover with no game in progress loads the new puzzle by itself', async ({ page }) => {
  await open(page, { time: new Date('2027-01-10T23:59:00-08:00') });
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #10 · Jan 10');
  await page.clock.fastForward('02:00');
  await expect(page.locator('#tag')).toHaveText('Daily GOAT #11 · Jan 11');
  await expect(page.locator('#newday')).toBeHidden();
});

for (const [label, days, tz] of [
  ['spring forward', ['2027-03-13', '2027-03-14', '2027-03-15'], 'America/New_York'],
  ['fall back', ['2027-11-06', '2027-11-07', '2027-11-08'], 'America/New_York']
]) {
  test(`DST ${label}: one puzzle number per local day`, async ({ browser }) => {
    const nos = [];
    for (const d of days) {
      for (const hour of ['00:30', '23:30']) {
        const ctx = await browser.newContext({ timezoneId: tz, viewport: { width: 390, height: 844 } });
        const page = await ctx.newPage();
        const b = createBackend();
        await b.install(ctx);
        // Midnight-adjacent local times on each side of the change, built from the zone's real offset.
        const offset = await page.evaluate(([d, h]) => { const t = new Date(`${d}T${h}:00`); return -t.getTimezoneOffset(); }, [d, hour]);
        const sign = offset >= 0 ? '+' : '-', hh = String(Math.floor(Math.abs(offset) / 60)).padStart(2, '0'), mm = String(Math.abs(offset) % 60).padStart(2, '0');
        await page.clock.install({ time: new Date(`${d}T${hour}:00${sign}${hh}:${mm}`) });
        await page.goto('http://127.0.0.1:4173/');
        const tag = await page.locator('#tag').filter({ hasText: '#' }).textContent();
        nos.push([d, hour, Number(tag.match(/#(\d+)/)[1])]);
        await ctx.close();
      }
    }
    const first = nos[0][2];
    expect(nos.map(x => x[2])).toEqual([first, first, first + 1, first + 1, first + 2, first + 2]);
  });
}

test('streak cases on load: skipped day shows 0, consecutive win adds 1', async ({ page }) => {
  const { backend: b } = await open(page, { storage: { 'goat-stats': { played: 2, wins: 2, streak: 2, maxStreak: 2, lastWin: '2027-01-08', lastPlayed: '2027-01-08' } } });
  await expect(page.locator('#sStreak')).toHaveText('0');
  await playToEnd(page, b, true);
  await expect(page.locator('#sStreak')).toHaveText('1');
  await page.clock.setSystemTime(NOON('2027-01-11'));
  await page.reload();
  await expect(page.locator('#sStreak')).toHaveText('1');
  await playToEnd(page, b, true, '2027-01-11');
  await expect(page.locator('#sStreak')).toHaveText('2');
  await expect(page.locator('#side .sgrid b').nth(1)).toHaveText('2');
});

test('practice rounds never change daily stats', async ({ page }) => {
  const { backend: b } = await open(page);
  await page.locator('#cats [data-practice]').first().click();
  await expect(page.locator('#tag')).toHaveText('Practice round');
  const names = await page.locator('#chips button').allTextContents();
  for (const n of names.slice(0, 5)) { if (await page.locator('#play').isHidden()) break; await chip(page, n).click(); }
  await expect(page.locator('#play')).toBeHidden();
  await expect(page.locator('#sPlayed')).toHaveText('0');
  await expect(page.locator('#ptally')).toContainText('Practice: 1 played');
  await expect.poll(() => b.eventsNamed('practice_start').length).toBe(1);
  expect(b.eventsNamed('game_complete')).toHaveLength(0);
});

test('analytics blocked: gameplay unaffected, events stay queued', async ({ page }) => {
  const b = createBackend(); b.block.add('track');
  const { errors } = await open(page, { backend: b });
  await playToEnd(page, b, true);
  await expect(page.locator('#side h2').first()).toHaveText('Found it in 2');
  await page.clock.fastForward(3000);
  const q = await page.evaluate(() => JSON.parse(localStorage.getItem('goat-events-queue')));
  expect(q.map(e => e.event)).toEqual(expect.arrayContaining(['visit', 'game_start', 'game_complete']));
  expect(realErrors(errors)).toEqual([]);
  b.block.delete('track');
  await page.clock.fastForward(1000);
  await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
  await expect.poll(() => b.eventsNamed('game_complete').length).toBe(1);
});

test('crowd vote category: cast and switch', async ({ page }) => {
  const { backend: b } = await open(page);
  await page.locator('#cats [data-votecat]').first().click();
  await expect(page.locator('#tag')).toHaveText('Crowd vote');
  await page.locator('#vote').getByRole('button', { name: 'Chess', exact: true }).click();
  await expect(page.locator('#vote .mine')).toContainText('Your vote: Chess');
  await page.locator('#vote').getByRole('button', { name: 'Catan', exact: true }).click();
  await expect.poll(() => Object.values(b.votes['community-board01'] || {})).toEqual(['Catan']);
  await expect(page.locator('#side h2')).toHaveText('Catan leads');
});

test('before launch day: notice and practice, no excused date', async ({ page }) => {
  const b = createBackend({ config: { launch_date: null } });
  await open(page, { backend: b });
  await expect(page.locator('#notice')).toContainText('Daily GOAT #1 starts soon.');
  await expect(page.locator('#tag')).toHaveText('Practice round');
  expect(await page.evaluate(() => localStorage.getItem('goat-excused'))).toBeNull();
});

test('colorblind: every guess state has words, and tier colors differ in brightness', async ({ page }) => {
  const { backend: b } = await open(page);
  await playToEnd(page, b, false);
  for (const t of await page.locator('#slots .bd').allTextContents()) expect(t).toMatch(/^#\d+ · (GOAT|Hot|Warm|Cold|Not top 10)/);
  const lum = await page.evaluate(() => ['t0', 't1', 't2', 't3', 't4'].map(c => {
    const el = document.createElement('i'); el.className = c; document.body.append(el);
    const [r, g, b] = getComputedStyle(el).backgroundColor.match(/\d+/g).map(Number).map(v => v / 255).map(v => v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4);
    el.remove(); return .2126 * r + .7152 * g + .0722 * b;
  }));
  const sorted = [...lum].sort((a, b) => a - b);
  for (let i = 1; i < sorted.length; i++) expect(sorted[i] - sorted[i - 1]).toBeGreaterThan(0.1);
});

test('mobile layout: board in the first screen, no horizontal scroll at 360px', async ({ page }, info) => {
  test.skip(!info.project.name.endsWith('phone'), 'phone sizes only');
  await open(page);
  await expect(page.locator('#tag')).toContainText('Daily GOAT #');
  const box = await page.locator('#slots .slot').first().boundingBox();
  expect(box.y + box.height).toBeLessThan(844);
  expect(await noOverflow(page)).toBe(true);
  await page.setViewportSize({ width: 360, height: 740 });
  expect(await noOverflow(page)).toBe(true);
});

test('accessibility: axe finds no serious issues on the main states', async ({ page }) => {
  const { backend: b } = await open(page);
  await expect(page.locator('#tag')).toContainText('Daily GOAT #');
  // Let the guess flip animation finish so contrast is measured on the settled colors.
  const scan = async () => (await page.waitForTimeout(700), await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa']).analyze()).violations
    .filter(v => v.impact === 'serious' || v.impact === 'critical').map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).slice(0, 3).join(', ')}`);
  expect(await scan()).toEqual([]);
  await playToEnd(page, b, true);
  expect(await scan()).toEqual([]);
  await page.locator('#side').getByRole('button', { name: b.puzzles[TODAY].ranking[1].name, exact: true }).click();
  await expect(page.locator('#side .big')).toBeVisible();
  expect(await scan()).toEqual([]);
  const small = await page.evaluate(() => [...document.querySelectorAll('button, input:not([type=checkbox]), select, textarea')]
    .filter(el => el.offsetParent && el.getBoundingClientRect().height < 44).map(el => el.id || el.textContent.trim()));
  expect(small).toEqual([]);
});

test("today's category is never offered as a practice round", async ({ page }) => {
  const { backend: b } = await open(page);
  await expect(page.locator('#tag')).toContainText('Daily GOAT #10');
  await expect(page.locator(`#cats [data-practice="${b.puzzles[TODAY].slug}"]`)).toHaveCount(0);
  await expect(page.locator('#cats [data-practice]')).toHaveCount(8);
});
