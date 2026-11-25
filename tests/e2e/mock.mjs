// In-memory stand-in for the Supabase REST API, implementing the same functions, error codes and rules
// as supabase/migrations. Every e2e test runs against this, never the live project.
import { G, bundled } from '../unit/load-core.mjs';

export const PASS = 'test-owner-pass';
const err = (message, status = 400) => ({ status, body: { code: 'P0001', message } });

export function createBackend(opts = {}) {
  const s = {
    config: { k: 100, launch_date: '2027-01-01', blend_tiers: [1, 500], voting_enabled: true, suggestions_enabled: true, analytics_enabled: true, ...(opts.config || {}) },
    catalog: bundled.map(c => ({ ...c, kind: 'daily', active: true, needs_clues: false })).concat(opts.extraCatalog || [
      { slug: 'community-board01', name: 'Board game', title: 'GOAT board game', kind: 'vote', active: true, opts: ['Catan', 'Chess', 'Monopoly', 'Scrabble'].map(name => ({ name, est: 0 })), clues: {} }
    ]),
    votes: {},          // slug -> { player: pick }
    puzzles: {},        // date -> snapshot
    suggestions: [],
    events: new Map(),  // event_id -> event
    sessions: {},       // token -> { expires, revoked }
    loginAttempts: 0,
    calls: [],
    offline: false,     // every request fails at the network level
    failNext: {},       // fn -> number of upcoming calls that fail with a network error
    block: new Set(),   // function names that fail at the network level
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

  const owner = token => {
    const x = s.sessions[token];
    if (!x || x.revoked || x.expires < Date.now()) throw err('not_owner');
  };

  const fns = {
    get_catalog: () => s.catalog.filter(c => c.active).map(c => ({ slug: c.slug, name: c.name, title: c.title, kind: c.kind, season: null, source: 'builtin', opts: c.opts, clues: c.clues, ...ranked(c) })),
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
        if (!/^[0-9a-f-]{36}$/.test(e.event_id) || !['visit', 'game_start', 'game_complete', 'pick_vote', 'share', 'practice_start', 'suggest', 'vote_error', 'offline'].includes(e.event)) throw err('bad_input');
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
    owner_delete_player: ({ p_token }) => { owner(p_token); return { votes: 0, suggestions: 0, events: 0 }; }
  };

  s.install = async (target) => {
    await target.route('https://mzlbnsibalthsycmvshm.supabase.co/rest/v1/**', async route => {
      const req = route.request(), url = new URL(req.url());
      const path = url.pathname.replace('/rest/v1/', '');
      const fn = path.startsWith('rpc/') ? path.slice(4) : path;
      s.calls.push(fn);
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
    // Third-party fonts aren't needed for the tests and may be unreachable.
    await target.route(/fonts\.(googleapis|gstatic)\.com/, route => route.fulfill({ status: 200, contentType: 'text/css', body: '' }));
  };
  return s;
}
