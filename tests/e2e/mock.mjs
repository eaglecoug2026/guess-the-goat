// In-memory stand-in for the Supabase REST API, implementing the same functions, error codes and rules
// as supabase/migrations. Every e2e test runs against this, never the live project.
import { G, bundled } from '../unit/load-core.mjs';

export const PASS = 'test-owner-pass';
export const LEAVE_OUT_CODE = 'test-leave-out-code-0123456789';
const err = (message, status = 400) => ({ status, body: { code: 'P0001', message } });

export function createBackend(opts = {}) {
  const s = {
    config: { k: 100, launch_date: '2027-01-01', blend_tiers: [1, 500], voting_enabled: true, suggestions_enabled: true, analytics_enabled: true, takes_enabled: true, ...(opts.config || {}) },
    catalog: bundled.map(c => ({ ...c, kind: 'daily', active: true, needs_clues: false })).concat(opts.extraCatalog || [
      { slug: 'community-board01', name: 'Board game', title: 'GOAT board game', kind: 'vote', active: true, opts: ['Catan', 'Chess', 'Monopoly', 'Scrabble'].map(name => ({ name, est: 0 })), clues: {} }
    ]),
    votes: {},          // slug -> { player: pick }
    takes: [],          // { id, slug, player, author, pick, reason, seed, hidden, at, edited }
    replies: [],        // { id, take, player, author, body, hidden, at, edited } (0013)
    blocked: ['zzbadword'],
    puzzles: {},        // date -> snapshot
    suggestions: [],
    events: new Map(),  // event_id -> event
    sessions: {},       // token -> { expires, revoked }
    loginAttempts: 0,
    calls: [],
    beacons: [],        // visit counts sent to proctorpilot.com (D-35), as parsed JSON
    leftOut: [],        // player IDs put on site_stats_left_out
    offline: false,     // every request fails at the network level
    failNext: {},       // fn -> number of upcoming calls that fail with a network error
    block: new Set(),   // function names that fail at the network level
    // opts.delay: { fn: ms } holds that function's response back
    nextId: 1
  };

  const counts = slug => {
    const c = {}; for (const pick of Object.values(s.votes[slug] || {})) c[pick] = (c[pick] || 0) + 1; return c;
  };
  const ranked = c => {
    const r = G.blendRanking(c.opts, counts(c.slug), s.config.k);
    return { ...r, tier: G.tierName(r.total_votes, s.config.blend_tiers) };
  };
  s.puzzleFor = date => {
    if (s.puzzles[date]) return s.puzzles[date];
    const no = G.puzzleNo(date, s.config.launch_date);
    if (!no || no < 1) return null;
    const dailies = s.catalog.filter(c => c.kind === 'daily' && c.active);
    const c = dailies[(no - 1) % dailies.length];
    const r = ranked(c);
    const answer = r.ranking[0].name;
    s.puzzles[date] = {
      puzzle_date: date, puzzle_no: no, slug: c.slug, name: c.name, title: c.title, ranking: r.ranking, answer,
      clues: c.clues[answer], k: r.k, total_votes: r.total_votes, tier: r.tier, frozen_at: new Date().toISOString(), correction_note: null
    };
    return s.puzzles[date];
  };
  s.answerFor = date => s.puzzleFor(date).answer;
  s.wrongFor = (date, n) => s.puzzleFor(date).ranking.slice(1).map(e => e.name).slice(0, n);
  s.eventsNamed = name => [...s.events.values()].filter(e => e.event === name);

  const takeJson = (t, player) => ({ id: t.id, author: t.author, pick: t.pick, reason: t.reason, seed: t.seed, mine: !!player && t.player === player, hidden: t.hidden, at: t.at,
    edited: !!t.edited, replies: s.replies.filter(r => r.take === t.id && !r.hidden).length });
  const blockedText = v => /(https?:\/\/|www\.)/i.test(v) || s.blocked.some(w => new RegExp('\\b' + w + '\\b', 'i').test(v));
  const replyJson = (r, player) => ({ id: r.id, take: r.take, author: r.author, body: r.body, mine: !!player && r.player === player, hidden: r.hidden, at: r.at, edited: !!r.edited });
  // One starter take per category, picking its #2 (D-31).
  for (const c of s.catalog) if (c.opts.length > 1) s.takes.push({ id: s.nextId++, slug: c.slug, player: null, author: 'Starter ' + c.slug.slice(0, 10), pick: c.opts[1].name, reason: 'A starter take for ' + c.name + '.', seed: true, hidden: false, at: '2027-01-01T00:00:00Z' });

  const owner = token => {
    const x = s.sessions[token];
    if (!x || x.revoked || x.expires < Date.now()) throw err('not_owner');
  };

  const fns = {
    get_catalog: () => s.catalog.filter(c => c.active).map(c => ({ slug: c.slug, name: c.name, title: c.title, kind: c.kind, season: null, source: 'builtin', grp: c.grp || null, sub: c.sub || null, opts: c.opts, clues: c.clues, ...ranked(c) })),
    get_takes: ({ p_slug, p_player }) => {
      const vis = s.takes.filter(t => t.slug === p_slug && (!t.hidden || (p_player && t.player === p_player)));
      vis.sort((a, b) => (a.seed - b.seed) || (b.at < a.at ? -1 : b.at > a.at ? 1 : b.id - a.id));
      return { takes: vis.slice(0, 60).map(t => takeJson(t, p_player)), total: s.takes.filter(t => t.slug === p_slug && !t.hidden).length };
    },
    take_page: ({ p_slug, p_player, p_limit, p_after_seed, p_after_at, p_after_id }) => {
      s.pageCalls = (s.pageCalls || 0) + 1;
      const n = Math.min(Math.max(p_limit || 5, 1), 20);
      const cmp = (a, b) => (a.seed - b.seed) || (b.at < a.at ? -1 : b.at > a.at ? 1 : b.id - a.id);
      const after = p_after_id == null ? null : { seed: !!p_after_seed, at: p_after_at, id: p_after_id };
      const vis = s.takes.filter(t => t.slug === p_slug && !t.hidden && !(p_player && t.player === p_player) && (!after || cmp(after, t) < 0)).sort(cmp);
      const mine = p_player && after == null ? s.takes.find(t => t.slug === p_slug && t.player === p_player) : null;
      return { takes: vis.slice(0, n).map(t => takeJson(t, p_player)), more: vis.length > n,
               total: s.takes.filter(t => t.slug === p_slug && !t.hidden).length, mine: mine ? takeJson(mine, p_player) : null };
    },
    post_take: ({ p_player, p_slug, p_pick, p_reason, p_author }) => {
      if (s.config.takes_enabled === false) throw err('disabled');
      const clean = v => (v == null ? '' : String(v)).trim().replace(/\s+/g, ' ');
      const pick = clean(p_pick), reason = clean(p_reason), author = clean(p_author) || null;
      if (!p_player || p_player.length < 8 || !pick || pick.length > 40 || reason.length < 2 || reason.length > 280 || (author && author.length > 24)) throw err('bad_input');
      const c = s.catalog.find(x => x.slug === p_slug && x.active); if (!c) throw err('bad_input');
      const bad = v => /(https?:\/\/|www\.)/i.test(v) || s.blocked.some(w => new RegExp('\\b' + w + '\\b', 'i').test(v));
      if (bad(pick) || bad(reason) || (author && bad(author))) throw err('blocked');
      // Mirrors public.match_pick (0011): exact name first, then a last name only one contender has.
      const lp = pick.toLowerCase();
      let o = c.opts.find(x => x.name.toLowerCase() === lp);
      if (!o && !/\s/.test(lp) && /\p{L}/u.test(lp)) {
        const hits = c.opts.filter(x => { const b = x.name.trim().replace(/,?\s+(jr\.?|sr\.?|ii|iii|iv)$/i, ''); return /\s/.test(b) && b.replace(/^.*\s/, '').toLowerCase() === lp; });
        if (hits.length === 1) o = hits[0];
      }
      let voted = false;
      if (o && s.config.voting_enabled !== false) { (s.votes[p_slug] ||= {})[p_player] = o.name; voted = true; }
      let t = s.takes.find(x => x.slug === p_slug && x.player === p_player);
      if (!t) { t = { id: s.nextId++, slug: p_slug, player: p_player, seed: false, hidden: false, at: new Date().toISOString() }; s.takes.push(t); }
      const np = o ? o.name : pick;
      if (t.pick !== undefined && (t.author !== author || t.pick !== np || t.reason !== reason)) t.edited = true;
      Object.assign(t, { author, pick: np, reason });
      return { take: takeJson(t, p_player), voted, pick: o ? o.name : null };
    },
    post_reply: ({ p_player, p_take, p_body, p_author }) => {
      if (s.config.takes_enabled === false) throw err('disabled');
      const clean = v => (v == null ? '' : String(v)).trim().replace(/\s+/g, ' ');
      const body = clean(p_body), author = clean(p_author) || null;
      if (!p_player || p_player.length < 8 || body.length < 2 || body.length > 280 || (author && author.length > 24)) throw err('bad_input');
      const t = s.takes.find(x => x.id === p_take && !x.hidden); if (!t) throw err('not_found');
      if (blockedText(body) || (author && blockedText(author))) throw err('blocked');
      const r = { id: s.nextId++, take: p_take, player: p_player, author, body, hidden: false, at: new Date().toISOString(), edited: false };
      s.replies.push(r);
      return replyJson(r, p_player);
    },
    edit_reply: ({ p_player, p_id, p_body }) => {
      if (s.config.takes_enabled === false) throw err('disabled');
      const body = (p_body == null ? '' : String(p_body)).trim().replace(/\s+/g, ' ');
      if (!p_player || p_player.length < 8 || body.length < 2 || body.length > 280) throw err('bad_input');
      if (blockedText(body)) throw err('blocked');
      const r = s.replies.find(x => x.id === p_id && x.player === p_player); if (!r) throw err('not_found');
      if (r.body !== body) r.edited = true;
      r.body = body;
      return replyJson(r, p_player);
    },
    // Mirrors public.reply_page: oldest first, cursor (at, id), own hidden replies for their author only.
    reply_page: ({ p_take, p_player, p_limit, p_after_at, p_after_id }) => {
      (s.replyCalls ||= []).push({ p_take, p_after_id });
      const n = Math.min(Math.max(p_limit || 5, 1), 20);
      const t = s.takes.find(x => x.id === p_take && !x.hidden);
      const cmp = (a, b) => a.at < b.at ? -1 : a.at > b.at ? 1 : a.id - b.id;
      const after = p_after_id == null ? null : { at: p_after_at, id: p_after_id };
      const vis = t ? s.replies.filter(r => r.take === p_take && (!r.hidden || (p_player && r.player === p_player)) && (!after || cmp(r, after) > 0)).sort(cmp) : [];
      return { replies: vis.slice(0, n).map(r => replyJson(r, p_player)), more: vis.length > n,
               total: t ? s.replies.filter(r => r.take === p_take && !r.hidden).length : 0 };
    },
    owner_replies: ({ p_token }) => {
      owner(p_token);
      return s.replies.slice().reverse().map(r => { const t = s.takes.find(x => x.id === r.take) || {}; return { ...replyJson(r, null), slug: t.slug, take_author: t.author, take_pick: t.pick }; });
    },
    owner_hide_reply: ({ p_token, p_id, p_hidden }) => { owner(p_token); const r = s.replies.find(x => x.id === p_id); if (!r) throw err('bad_input'); r.hidden = p_hidden !== false; return null; },
    owner_takes: ({ p_token }) => { owner(p_token); return s.takes.filter(t => !t.seed).map(t => ({ ...takeJson(t, null), slug: t.slug })); },
    owner_hide_take: ({ p_token, p_id, p_hidden }) => { owner(p_token); const t = s.takes.find(x => x.id === p_id); if (!t) throw err('bad_input'); t.hidden = p_hidden !== false; return null; },
    get_daily: ({ p_date }) => s.puzzleFor(p_date),
    cast_vote: ({ p_player, p_slug, p_pick }) => {
      if (s.config.voting_enabled === false) throw err('disabled');
      const c = s.catalog.find(x => x.slug === p_slug && x.active);
      if (!c || !c.opts.some(o => o.name === p_pick)) throw err('bad_pick');
      (s.votes[p_slug] ||= {})[p_player] = p_pick;
      return null;
    },
    suggest: ({ p_player, p_name, p_opts }) => {
      if (s.config.suggestions_enabled === false) throw err('disabled');
      const name = String(p_name || '').trim().replace(/\s+/g, ' ');
      if (name.length < 2 || name.length > 60) throw err('bad_input');
      if (s.suggestions.some(x => x.name.toLowerCase() === name.toLowerCase() && x.status !== 'dismissed')) throw err('duplicate');
      const id = `00000000-0000-4000-8000-${String(s.nextId++).padStart(12, '0')}`;
      s.suggestions.push({ id, name, opts: p_opts || [], voter: p_player, status: 'pending', created_at: new Date().toISOString() });
      return id;
    },
    my_suggestions: ({ p_player }) => s.suggestions.filter(x => x.voter === p_player).map(({ voter, ...x }) => x),
    track: ({ p_events }) => {
      if (!Array.isArray(p_events) || !p_events.length || p_events.length > 50) throw err('bad_input');
      for (const e of p_events) {
        if (!/^[0-9a-f-]{36}$/.test(e.event_id) || !['visit', 'game_start', 'game_complete', 'pick_vote', 'share', 'practice_start', 'suggest', 'vote_error', 'offline', 'hint', 'give_up', 'take_post'].includes(e.event)) throw err('bad_input');
        if (e.ref != null && (e.ref.length < 8 || e.ref.length > 64)) throw err('bad_input');
      }
      let n = 0; for (const e of p_events) if (!s.events.has(e.event_id)) { s.events.set(e.event_id, e); n++; }
      return n;
    },
    owner_login: ({ p_pass }) => {
      if (++s.loginAttempts > 5) throw err('rate_limited');
      if (p_pass !== PASS) return null;
      const token = 'tok' + Math.random().toString(36).slice(2).padEnd(40, 'x');
      s.sessions[token] = { expires: Date.now() + 12 * 3600e3, revoked: false };
      return token;
    },
    owner_logout: ({ p_token }) => { if (s.sessions[p_token]) s.sessions[p_token].revoked = true; return null; },
    owner_revoke_all: ({ p_token }) => { owner(p_token); for (const x of Object.values(s.sessions)) x.revoked = true; return null; },
    owner_queue: ({ p_token }) => { owner(p_token); return s.suggestions.filter(x => x.status === 'pending').map(({ id, name, opts, created_at }) => ({ id, name, opts, created_at })); },
    owner_needs_clues: ({ p_token }) => { owner(p_token); return []; },
    owner_schedule: ({ p_token }) => { owner(p_token); return Array.from({ length: 30 }, (_, i) => ({ date: G.addDays('2027-01-10', i), slug: null, note: null, frozen_slug: null })); },
    owner_stats: ({ p_token }) => { owner(p_token); return { day: '2027-01-10', players: 3, completions: 2, votes: 1, shares: 1, top_ip_hashes: [] }; },
    owner_review_suggestion: ({ p_token, p_id, p_action, p_opts }) => {
      owner(p_token);
      const x = s.suggestions.find(y => y.id === p_id && y.status === 'pending');
      if (!x) throw err('bad_input');
      if (p_action === 'dismiss') { x.status = 'dismissed'; return null; }
      if (!Array.isArray(p_opts) || p_opts.length < 4 || p_opts.length > 16) throw err('bad_input');
      const slug = 'community-' + p_id.slice(-8);
      s.catalog.push({ slug, name: x.name, title: 'GOAT ' + x.name.toLowerCase(), kind: 'vote', active: true, opts: p_opts.map(name => ({ name, est: 0 })), clues: {} });
      x.status = 'added';
      return slug;
    },
    owner_remove_category: ({ p_token, p_slug }) => { owner(p_token); const c = s.catalog.find(x => x.slug === p_slug && x.active); if (!c) throw err('bad_input'); c.active = false; return null; },
    owner_set_schedule: ({ p_token }) => { owner(p_token); return null; },
    owner_set_correction: ({ p_token, p_date, p_note }) => { owner(p_token); const p = s.puzzles[p_date]; if (!p) throw err('bad_input'); p.correction_note = p_note || null; return null; },
    owner_delete_player: ({ p_token }) => { owner(p_token); return { votes: 0, suggestions: 0, events: 0, takes: 0, replies: 0 }; },
    site_stats_leave_me_out: ({ p_code, p_player }) => {
      if (p_code !== LEAVE_OUT_CODE) throw err('not allowed', 403);
      if (typeof p_player !== 'string' || p_player.length < 8 || p_player.length > 64) throw err('bad_input');
      if (!s.leftOut.includes(p_player)) s.leftOut.push(p_player);
      return { ok: true };
    }
  };

  s.install = async (target) => {
    await target.route('https://mzlbnsibalthsycmvshm.supabase.co/rest/v1/**', async route => {
      const req = route.request(), url = new URL(req.url());
      const path = url.pathname.replace('/rest/v1/', '');
      const fn = path.startsWith('rpc/') ? path.slice(4) : path;
      s.calls.push(fn);
      if (opts.delay && opts.delay[fn]) await new Promise(r => setTimeout(r, opts.delay[fn]));
      if (s.offline || s.block.has(fn) || (s.failNext[fn] > 0 && s.failNext[fn]--)) return route.abort('internetdisconnected');
      if (req.headers().apikey !== 'sb_publishable_1RuU3_8Jetrt6mrdl6-05g_y1XG5n54') return route.fulfill({ status: 401, json: { message: 'bad key' } });
      if (fn === 'config') {
        return route.fulfill({ json: Object.entries(s.config).map(([key, value]) => ({ key, value })) });
      }
      const impl = fns[fn];
      if (!impl) return route.fulfill({ status: 404, json: { code: 'PGRST202', message: 'Could not find the function' } });
      try {
        const out = impl(req.postDataJSON() || {});
        return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(out === undefined ? null : out) });
      } catch (e) {
        if (e && e.status) return route.fulfill({ status: e.status, json: e.body });
        throw e;
      }
    });
    // Visit counts for the owner's Site Stats page (visit.js, D-35): recorded, never sent.
    await target.route('https://proctorpilot.com/api/visit.php', async route => {
      try { s.beacons.push(JSON.parse(route.request().postData() || 'null')); } catch (e) { s.beacons.push(null); }
      return route.fulfill({ status: 204, body: '' });
    });
    // Third-party fonts aren't needed for the tests and may be unreachable.
    await target.route(/fonts\.(googleapis|gstatic)\.com/, route => route.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  };
  return s;
}
