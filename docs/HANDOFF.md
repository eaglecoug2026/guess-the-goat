# The GOAT: MVP implementation handoff

**Status:** Agreed by Claude and ChatGPT (2026-11-25), pending ChatGPT's review of this document. Implementation starts only when **Peter authorizes** it.
**This document is authoritative.** Context: `PRODUCT.md` (current state), `ROADMAP.md` (phases), `DECISIONS.md` (rationale, D-xx references).
**Scope rule:** build exactly what's below. Anything else needs a new decision in `DECISIONS.md`.

**Contents**
1. Current architecture
2. MVP scope
3. Gameplay logic and formulas
4. Daily puzzle scheduling
5. Database migrations
6. Security requirements
7. Client changes
8. Offline resilience
9. Analytics
10. Privacy
11. Mobile UX and accessibility
12. Category import and validation
13. Implementation sequence
14. Acceptance criteria
15. Testing
16. Deployment
17. Rollback and recovery
18. Deferred
19. Open items

---

## 1. Current architecture
Full detail is in `PRODUCT.md`. In summary:
- **Front end:** one static `index.html` with vanilla JS and no build step, served by GitHub Pages from `main` at the root.
- **Back end:** Supabase `mzlbnsibalthsycmvshm` (free tier). PostgREST is called directly with the publishable key.
  - Existing tables: `suggestions`, `categories`, `votes`, `owner_secret`.
  - Existing functions: `suggest`, `cast_vote`, `check_owner`, `review_suggestion`, `remove_category`.
  - The existing migration `goat_core` is applied in Supabase but **not yet in the repo**. Step 1 exports it as `supabase/migrations/0001_goat_core.sql`.
- **Identity:** a random ID in localStorage. No accounts.
- **Production data:** no community categories or votes exist yet, so the migration has nothing to preserve beyond the owner secret.

## 2. MVP scope
**P0, required for the soft launch:**
1. Catalog and frozen daily puzzles in Supabase (§4, §5)
2. Personal GOAT picks become real votes, shown with blended rankings and disclosure (§3)
3. Server-side vote counts and IP-hash rate limits (§5, §6)
4. Private suggestion queue and owner session tokens, including the needs-clues flag (§6, §7)
5. New share flow (§7)
6. First-party analytics (§9)
7. Colorblind-safe indicators (§11)
8. Offline resilience (§8)
9. Content: 48 categories validated and fact-checked (§12)
10. Privacy page, moderation process, and GitHub Pages enabled (§10, §17)

**P1, same release:**

11. Daily-first mobile layout and first-visit how-to (§11)
12. Streak reset on load (§3)
13. Separate daily and practice stats (§7)
14. Accessibility, mobile and cross-browser test pass (§15)

Deferred work is listed in §18.

## 3. Gameplay logic and formulas
- **Guessing:** 5 guesses maximum. A guess is any contender in the category's 16 that hasn't been guessed yet. A guess wins if it's the frozen answer.
- **Guess feedback:** rank and blended share from the **frozen ranking**. The tier is shown as a word:
  - #1 = **GOAT**
  - #2–3 = **Hot**
  - #4–6 = **Warm**
  - #7–10 = **Cold**
  - otherwise **Not top 10**
- **Clues:** clue 1 is visible at the start. Each miss unlocks the next, up to 4. All 4 show at the end. These are the answer's clue set from the snapshot.
- **Estimated share** `e` = whole-percent estimate ÷ 100. Contenders outside the top 10 have `e = 0`.
- **Blended share:** `b = (v + k·e) / (V + k)`, where `v` = the contender's real votes, `V` = the category's total real votes, and `k = config.k` (default 100). Ranks are sorted by `b` descending. Ties are broken by `e` descending, then by name.
- **Disclosure tier,** by `V`:
  - 0 → "Estimated ranking"
  - 1–499 → "Blended community ranking · N votes"
  - ≥500 → "Community ranking · N votes (includes estimated weighting)"
- **Hot Take Score:** `round(100 × (1 − b_pick / b_top))`, using the frozen snapshot shares (0 if the pick is #1, 100 if `b_pick = 0`). Labels are unchanged (see `PRODUCT.md`).
- **Personal pick = vote:** shown after the game ends. Selecting a pick calls `cast_vote(slug, pick)`. Changing it calls `cast_vote` again, which upserts the same row. The Hot Take Score uses the frozen snapshot, so votes never change it.
- **Streak:** counts consecutive daily puzzle numbers **won**.
  - On load, if the last won puzzle number is below `today − 1` and none of the days between are **excused** (§8), the displayed streak is 0.
  - A loss sets it to 0.
- **Practice rounds** (Team GOAT, any non-today category) use the category's live blended ranking at the time the round starts, and clues for the live #1. A category whose live #1 has no clues isn't offered for practice. Practice never affects daily stats.

## 4. Daily puzzle scheduling
- **Day boundary:** the player's **local calendar date** (D-09). Puzzle number = `(local_date − config.launch_date)` in days + 1. It's computed from Y-M-D parts with `Date.UTC`, never by adding 24-hour intervals, so it's **safe across daylight saving changes**.
- **One date = one puzzle worldwide** (D-08): `daily_puzzles` is keyed by `puzzle_date` and has a unique `puzzle_no`.
- **Freeze horizon ≥ 48 hours** (D-10):
  - A `pg_cron` job runs every day at 00:05 UTC and freezes every missing date through **UTC date + 3**.
  - The earliest time zone (UTC+14) reaches UTC date + 1 at 10:00 UTC, so frozen puzzles always exist at least 48 hours before any player can reach them.
- **Lazy safety net:** `get_daily(p_date)` freezes the date if it's missing and within the readable window, and logs `late_freeze` in `ops_log`.
- **Readable window:** the public can read puzzles for dates ≤ UTC date + 1, which covers UTC+14 players. Frozen puzzles further ahead are hidden.
- **Category selection at freeze:**
  1. An owner `schedule` row for that date wins, if the category is active and its blended #1 has clues.
  2. Otherwise: active `kind = 'daily'` categories with `season IS NULL`, whose blended #1 has a clue set, and that weren't used in the last 30 puzzles. Pick the one used least recently, breaking ties by slug.
  3. A category skipped because its #1 lacks clues gets `needs_clues = true`.
  4. If nothing is eligible, reuse the least recently used category that has clues, and log `pool_exhausted`.
- **Snapshot contents:** `puzzle_no`, `puzzle_date`, `slug`, `name`, `title`, `ranking` (an array of 16 entries: `name`, `est`, `votes`, `blended`, `rank`), `answer`, `clues` (4), `k`, `total_votes`, `tier`, `frozen_at`. A `BEFORE UPDATE OR DELETE` trigger rejects changes. The only exception is the owner-only `correction_note` column.
- **Return after midnight:** when the page regains focus or becomes visible, and once a minute while it's open, the client compares the local date with the loaded puzzle date. If they differ, it loads the new daily. A game in progress isn't interrupted; the client shows "A new GOAT is ready" with a button.

## 5. Database migrations
Each migration is a file in `supabase/migrations/`, applied in order and **committed before it's applied**. It comes with a matching rollback script in `supabase/rollback/` and an SQL test file in `supabase/tests/`.

| File | Contents |
|---|---|
| `0001_goat_core.sql` | Export of the already-applied migration (record only; not re-applied) |
| `0002_catalog.sql` | See the list below this table |
| `0003_daily.sql` | `daily_puzzles` (with the immutability trigger), `schedule`, `freeze_puzzle(date)`, `get_daily(date)`, and the `pg_cron` freeze job |
| `0004_owner_sessions.sql` | `owner_sessions`, `owner_login`, `owner_logout`, `owner_revoke_all`, and the owner functions. Moves the hash from `owner_secret` into `secrets`. Drops `check_owner`, `review_suggestion` and `remove_category`. |
| `0005_suggestions_private.sql` | Revokes public select on `suggestions`, adds `ip_hash`, adds `my_suggestions` and `owner_queue`, and rewrites `suggest` with IP limits |
| `0006_analytics.sql` | `events` with a unique client `event_id`, `track`, reporting views, and the retention cleanup job |

`0002_catalog.sql` creates:
- `config` (public, non-secret) and `secrets` (private)
- `catalog`, `catalog_votes`, `vote_counts` and its trigger
- `rate_limits` and the `check_rate(bucket, ip_hash, limit, window)` helper
- `ops_log`
- the functions `get_catalog` and `cast_vote` (rewritten to use slugs)
- migration of `categories` → `catalog (kind = 'vote', source = 'community')` and of `votes` → `catalog_votes`, then dropping the old tables

**Table definitions** (all with RLS enabled):
- `config(key text pk, value jsonb, public bool)`
  - Seeds: `k = 100`, `launch_date`, `blend_tiers = [1, 500]`, the rate limits from §6, `voting_enabled`, `suggestions_enabled`, `analytics_enabled` (all `true`), `repeat_window = 30`, `freeze_horizon_days = 3`.
- `secrets(key text pk, value text)`: `ip_salt` (random 32 bytes) and `owner_pass_hash`. No grants to `anon` or `authenticated`.
- `catalog`:
  - Key and labels: `slug text pk`, `name`, `title`, `kind ∈ {daily, vote}`, `season text null`
  - Content: `opts jsonb` (an array of `{name, est}` where `est` is a decimal), `clues jsonb` (`{contender: [4 strings]}`)
  - State: `active bool`, `needs_clues bool`, `source ∈ {builtin, community}`, `suggestion_id uuid null`, `created_at`, `updated_at`
- `catalog_votes(slug fk, player text, pick text, created_at, updated_at)` with PK `(slug, player)`. Not publicly readable.
- `vote_counts(slug, pick, n)` with PK `(slug, pick)`, maintained by an `AFTER INSERT / UPDATE / DELETE` trigger on `catalog_votes`. Publicly readable.
- `daily_puzzles` (the §4 snapshot plus `correction_note text null`). Publicly readable inside the window.
- `schedule(puzzle_date pk, slug fk, note)`. Owner only.
- `owner_sessions(token_hash text pk, created_at, expires_at, revoked_at)`. Private.
- `rate_limits(bucket, ip_hash, window_start, count)` with PK `(bucket, ip_hash, window_start)`. Private.
- `events(event_id uuid pk, at, player, event, puzzle_no, ref, props jsonb)`. Private.
- `ops_log(id, at, kind, detail jsonb)`. Private.

**Function rules:**
- Every function is `SECURITY DEFINER` with `SET search_path = ''`. Public functions are granted to `anon, authenticated`. Everything else is revoked from `public`.
- Errors are raised as short codes: `rate_limited`, `bad_pick`, `duplicate`, `not_owner`, `disabled`, `bad_input`.
- The client maps each code to a friendly message.

## 6. Security requirements
1. **Public tables are read-only.** No `anon` insert, update or delete on any table. Every write goes through a function.
2. **Hidden data:** `catalog_votes`, `suggestions`, `events`, `rate_limits`, `owner_sessions`, `secrets` and `schedule` can't be read by the public. Neither can future dates in `daily_puzzles`.
3. **Owner authentication** (D-13):
   - `owner_login(pass)`: rate-limited to **5 per 15 minutes per IP hash**. On success it returns a token of 32 bytes from `gen_random_bytes`, base64url-encoded. Only `sha256(token)` is stored. The session expires after **12 hours**.
   - Every owner function takes the token and checks for a valid, unrevoked, unexpired session.
   - `owner_logout` revokes one session; `owner_revoke_all` revokes all of them.
   - The client stores the token in **sessionStorage only**. The passphrase is never stored and never sent anywhere except `owner_login`.
4. **IP handling:**
   - Use the first entry of `x-forwarded-for` from `current_setting('request.headers', true)`.
   - Store it only as `encode(sha256(ip_salt || ip), 'hex')`.
   - If the IP is missing, use bucket `ip:unknown` with the same limits.
5. **Rate limits** (in `config`, generous because of shared IPs):
   - Votes: 120 per hour per IP hash
   - Suggestions: 10 per day per IP hash and 10 per day per player
   - Track: 600 per hour per IP hash
   - Owner login: 5 per 15 minutes
   - Exceeding a limit raises `rate_limited`.
6. **Input validation:** server-side length limits:
   - Names ≤ 60 characters, contenders ≤ 40, player and ref IDs 8–64 characters
   - Contender list 0–16 for suggestions, 4–16 for adding
   - Event names from an allowlist, props ≤ 2 KB
7. **Kill switches:** `voting_enabled`, `suggestions_enabled` and `analytics_enabled`. When off, the function raises `disabled` and the client hides or pauses that feature. Gameplay is unaffected.
8. **Client output:** every server value is rendered with `textContent` or `esc()`. There's no `innerHTML` of raw data.
9. **The publishable key only** is in the client. No service key anywhere in the repo.
10. **Advisors:** after each migration, the Supabase security advisor shows no new ERROR-level findings. The `SECURITY DEFINER` warnings for the public functions listed here are expected and documented.

## 7. Client changes (`index.html`)
**Identity and local storage keys:**
- `goat-player`: random UUID (renamed from `goat-voter`, with the old value migrated)
- `goat-ref`: 8 random base36 characters for referral codes
- `goat-daily-<puzzle_no>`: game state
- `goat-puzzle-<date>`: cached frozen snapshot
- `goat-stats`: daily stats
- `goat-practice`: practice tally
- `goat-excused`: dates whose official puzzle failed to load
- `goat-events-queue`: queued analytics events
- `goat-howto-seen`
- The owner token is in sessionStorage only (`goat-owner-token`).

**Startup flow:**
1. Compute the local date and puzzle number. Render the layout immediately.
2. Load today's snapshot from the cache. If it's missing, call `get_daily(date)` and cache the result.
3. Call `get_catalog()` for practice and vote categories, and refresh counts every **60 seconds** while the page is visible.
4. Send the `visit` event, including `?r=` from the URL if present.

**Daily header:** "Daily GOAT #N · <local date>", the tier label and the vote count (§3).

**Game state** is saved after every guess and pick under `goat-daily-<puzzle_no>`, so a refresh mid-game restores it exactly.

**Personal pick:**
- Optimistic UI.
- On error: "Your pick didn't save" plus **Retry**. The local pick is kept.
- A retry calls the same upsert, so it can't create duplicates.

**Share** (D-18):
- Default text:
  `THE GOAT #N 🐐` / `<emoji grid> <guesses>/5 · Hot Take <score>` / `Can you find today's GOAT? <url>?r=<goat-ref>`
- The emoji grid comes from the tiers: GOAT 🟩, Hot 🟧, Warm 🟨, Cold 🟦, out ⬛.
- An "Include my pick" toggle, off by default, adds `My GOAT: <pick>`.
- The share never includes the answer's name unless the pick is included.
- Uses `navigator.share({text})` when available, otherwise the clipboard, otherwise a selectable textarea. Fires the `share` event with the method and spoiler flag.

**Stats** (P1):
- Daily: streak, max streak, played, win %, and a guess distribution (1–5 and X).
- Practice: a played and won tally, shown separately.

**Suggestions:**
- The form calls `suggest`. "Your suggestions" comes from `my_suggestions(player)`.
- The public "Up next" list is removed. The public sees only approved vote categories, inside Team GOAT, tagged **Vote**.

**Owner panel:**
- Sign-in uses `owner_login`.
- Sections: queue (add with editable contenders, or dismiss), live categories (remove), needs-clues list, schedule overrides for the next 30 dates, basic stats from `owner_stats` (today's players, completions, votes, shares, top IP-hash volumes), sign out, and sign out everywhere.
- An expired token returns the panel to sign-in with a notice.

**Team GOAT:** 8 random practice categories plus Shuffle, below the daily board under the heading "More GOATs to play". Vote categories are appended.

## 8. Offline resilience
- **Official puzzle sources:** the server, or a cached copy of the server snapshot for that same date. **Never anything else** (D-11).
- **If the official puzzle can't load and isn't cached:**
  - Show "Today's GOAT can't load right now. We'll keep trying."
  - Retry with backoff: 5s, 15s, 30s, then every 60s.
  - Offer **"Play a practice round"** from the bundled catalog, clearly labeled Practice.
  - Add the date to `goat-excused`. An excused date never breaks the streak (D-12).
- **Bundled catalog:** a JSON copy of the catalog is embedded in `index.html` at build time. It's used only for practice rounds and as display fallback text, and **never** for the daily.
- **Votes:** if `cast_vote` fails, keep the pick locally and show Retry. There's no silent background retry, so the user stays in control. The upsert makes duplicates impossible.
- **Analytics:** events go into `goat-events-queue` (max 200, oldest dropped) and are flushed later. Each event has a client `event_id` UUID, so the server ignores duplicates (`ON CONFLICT DO NOTHING`). Analytics failures are silent and never block the UI.
- **Suggestions:** on failure, show an inline error and keep the form contents.
- **Owner:** owner actions need the network and fail with a clear message.

## 9. Analytics
**Events** (allowlist; anything else is rejected):

| Event | Props |
|---|---|
| `visit` | `ref` (8-character code or null), `referrer_domain`, `standalone` (bool), `first_visit` (bool) |
| `game_start` | `puzzle_no` |
| `game_complete` | `puzzle_no`, `won`, `guesses` |
| `pick_vote` | `puzzle_no` or `slug`, `changed` (bool) |
| `share` | `puzzle_no`, `method` (`native` / `clipboard` / `manual`), `spoiler` (bool) |
| `practice_start` | `slug` |
| `suggest` | none |
| `vote_error` | `code` |
| `offline` | `what` (`daily` / `catalog` / `vote`) |

**Reporting views** (SQL only for the MVP):
- Daily players
- Returning players
- D1, D7 and D30 retention by first-visit cohort
- Games started and completed, and the completion rate
- **% of completed daily games with a `pick_vote`**
- Shares per completed game
- Referral visits
- **% of referred first visits that reach `game_complete`**
- Daily vote volume
- Average guesses

## 10. Privacy
Add a `privacy.html` page, linked in the footer. It must state:
- **On the device:** the anonymous player ID, referral code, game state and stats.
- **Sent to us:** picks and votes, suggestions and analytics events, tied to the anonymous ID; IP addresses **only as salted hashes** for rate limiting.
- **Retention:**
  - `events`: 13 months
  - `rate_limits`: 48 hours
  - votes: while the category exists
  - suggestions: until reviewed, plus 90 days if dismissed
- No ads, no cookies and no third-party trackers. Processor: Supabase (US).
- Rankings may blend estimates with real votes.
- **Deletion requests:** the contact email (open item O-3). The owner can delete a player's rows by player ID; the player finds their ID in a "Your data" note in the footer.

**Nightly cleanup:** a `pg_cron` job enforces the retention periods above.

**Moderation and content correction process:**
- Suggestions stay private until the owner approves them. Offensive content is removed immediately. Debates about private individuals are not allowed.
- **Fact errors:**
  - The owner fixes the `catalog` entry.
  - A published puzzle is never edited; for a live puzzle, the owner sets `correction_note`, which is shown under that puzzle.
  - All content changes go through a PR: validator, ChatGPT content review, Claude build check, Peter merges.

## 11. Mobile UX and accessibility
- **Layout order:** the header shows the brand and compact stats; then the daily board; then the reveal panel; then More GOATs to play; then suggestions; then the footer (owner sign-in, privacy, "Your data").
- At 390px wide, the daily board starts within the first screen. There's no horizontal scroll at 360px.
- **First-visit how-to:** one line above the board ("Find the crowd's #1 in 5 guesses. Misses show how close you got."), with a dismiss button. Stored in `goat-howto-seen`.
- **Colorblind-safe (P0):**
  - Every guess badge shows the **rank number plus a tier word**, e.g. `#2 · Hot · 19%`.
  - The legend repeats the words.
  - The tier colors differ in brightness as well as hue: Hot dark orange, Warm light yellow, Cold mid blue, Out gray.
  - Color is never the only signal.
- **Accessibility basics:**
  - Every control has a label and is at least 44×44px.
  - Visible focus rings.
  - `aria-live="polite"` for guess results and save errors.
  - Text contrast at least 4.5:1, including on the gold background.
  - The motion animation is disabled under `prefers-reduced-motion`.
- **iPhone home-screen mode:** keep the existing manifest and meta tags. Safe-area padding at the top and bottom.

## 12. Category import and validation
- **Source:** `content/categories.json`, an array of category objects:
  - Required fields: `id`, `label`, `title`, `kind`, `season` (null or a string), `opts`, `clues`
  - Optional: `sources`
  - `opts`: an array of 16 `[name, whole %]` pairs
  - `clues`: `{contender: [4]}`
  - Contains ChatGPT's 36 categories plus the 12 existing ones converted. **Claude writes clues for #2 and #3 of the 12 existing categories; ChatGPT reviews them.**
- **Validator:** `tools/validate-categories.mjs` (Node, no dependencies). Exits non-zero on any error and checks:
  - The `id` is unique and matches `^[a-z0-9-]{2,40}$`, and `label` and `title` aren't empty.
  - Exactly 16 contenders, unique ignoring case.
  - The top 10 are integers > 0 in descending order, summing to 80–100. The other 6 are 0.
  - `clues` has exactly 3 keys, equal to the 3 highest-estimate contenders, each with exactly 4 strings of ≤ 90 characters.
  - No clue contains its contender's full name or any word of 4+ letters from it (comparison ignores case and accents).
  - `kind` is `daily` or `vote`.
- **Import:** `tools/catalog-to-sql.mjs` generates an idempotent upsert (`supabase/seed/catalog.sql`) and the bundled catalog JSON block for `index.html`.
  - The seed upserts by `slug` and **never touches `daily_puzzles`**.
  - Removing a category sets `active = false`; categories are never deleted.
- **Fact-check gate:** before launch, every clue is checked by a person. The PR for the content includes a checklist with one line per category, plus who verified it and when.

## 13. Implementation sequence
Each step is its own branch and PR into `main`. Peter merges.
1. **`feat/backend`:**
   - Export `0001`, then write and apply `0002`–`0006` with rollback scripts and SQL tests.
   - Back up the tables first (§17).
   - Set `launch_date` (O-2) and create the `pg_cron` jobs.
   - Run the advisors.
2. **`feat/client`:** all of §7, §8, §9 and §11 against the new functions, plus Playwright tests.
3. **`feat/content`:** the validator, the import tool, the 48 categories and the bundled catalog. Seed the database.
4. **`feat/privacy-docs`:** `privacy.html`, README updates and a final docs sync. Peter enables Pages (O-4).
5. **Pre-launch:** fact-check sign-off, Peter's iPhone test, and a smoke test of the live URL. The soft launch starts on `launch_date`.

Backend changes ship **before** the client code that depends on them. The client checks feature availability and degrades gracefully if a function is missing.

## 14. Acceptance criteria
| Feature | Accepted when |
|---|---|
| Frozen daily | The same date returns the same `puzzle_no`, answer, ranking and clues on every call. An `UPDATE` or `DELETE` on a published row fails, except `correction_note` by the owner. Puzzles exist ≥ 48 hours ahead, as verified by a query after the cron job runs. |
| Local date and DST | With a mocked clock across the US spring-forward and fall-back dates, the puzzle number increases by exactly 1 per local day. |
| Midnight refresh | With a mocked clock passing midnight, refocusing the page offers the new puzzle and doesn't interrupt a game in progress. |
| Blended ranking | Unit tests reproduce §3 exactly for V = 0, 1, 150, 499, 500 and 5000, and show the correct tier label and vote count. |
| Clue mismatch | When a category's blended #1 lacks clues, it's skipped by `freeze_puzzle`, `needs_clues` is set, and it shows in the owner dashboard. |
| Personal vote | A pick creates one `catalog_votes` row. Changing it updates the same row (count unchanged, `pick` changed) and `vote_counts` reflects it. A retry after a failure creates no duplicate. |
| Rate limits | The 121st vote within an hour from one IP hash returns `rate_limited`. Normal play never reaches a limit. |
| Suggestions private | `anon` can't select from `suggestions`. `my_suggestions` returns only that player's rows. The public UI shows no pending items. |
| Owner session | Login returns a token. The database stores only its hash. Owner functions reject a missing, expired or revoked token. Six logins in 15 minutes from one IP hash are rate-limited. No passphrase or token is in localStorage. |
| Share | The default text has the puzzle number, grid, score and a URL with `?r=`, and **no answer name**. The toggle adds the pick. The native share, clipboard and textarea fallbacks all work. |
| Analytics | Each allowlisted event lands once, even when resent. Blocking the analytics endpoint changes nothing visible in gameplay. The reporting views return the metrics in §9. |
| Offline | With Supabase blocked: a cached daily is still playable, and an uncached daily shows the notice plus practice and never a substitute daily. The excused date doesn't break the streak. |
| Refresh mid-game | Reloading after 2 guesses restores the 2 guesses, the unlocked clues and the remaining guesses. |
| Streak | With a mocked date: skip a day → the streak shows 0 on load. A win on consecutive days → +1. An excused day → no break. |
| Colorblind | Every guess state has a text label. Automated grayscale screenshot review confirms the states are distinguishable. |
| Mobile layout | At 390×844, the daily board is visible without scrolling. There's no horizontal overflow at 360px. |
| Stats separation | Practice wins and losses never change the daily streak or win %. |
| Content | The validator passes on all 48 categories, the seed is idempotent, and the fact-check checklist is complete. |
| Privacy | `privacy.html` covers every item in §10 and is linked in the footer. |

## 15. Testing
- **SQL tests** (`supabase/tests/*.sql`) run as `anon` and owner inside a transaction that's rolled back. They cover every §14 database criterion, all RLS denials, function validation, rate limits, immutability, the freeze horizon and the trigger counts.
- **Unit tests** (`tests/unit/*.mjs`, Node): blended ranking, tiers, Hot Take, puzzle-number and DST math, the streak and excused logic, and share text.
- **End-to-end tests** (`tests/e2e`, Playwright, Chromium and WebKit, at 390×844 and 1280×900) with mocked Supabase responses:
  - Win and loss
  - Refresh mid-game
  - Vote, change the vote, fail and retry
  - All three share paths
  - Suggestions
  - Owner login, expiry and revocation
  - Offline (cached and uncached)
  - Midnight rollover
  - DST dates
  - Streak cases
  - Analytics blocked
  - No console errors and no horizontal overflow
- **Accessibility:** an automated check of labels, contrast and focus visibility on the main states (axe-core if available offline; otherwise scripted checks).
- **Manual:** Peter on a real iPhone, in Safari and as a home-screen app, before the soft launch.
- **Live smoke test** after each deploy: load the URL, play today's puzzle, cast a pick, and confirm one `visit`, `game_complete` and `pick_vote` landed.

## 16. Deployment
- **Branches:** each step's branch → PR with a test summary → Peter merges → GitHub Pages redeploys `main` in about 1 minute → live smoke test.
- **Database:** migrations are applied by Claude before the dependent client PR merges. Each migration is recorded in the PR along with the advisor output.
- **Releases:** tag `v0.1.0` at the soft launch, with patch tags for each later merge.
- **Config changes** (such as `k`, limits or kill switches) are made by SQL `UPDATE` on `config` and noted in `ops_log`. They need no deploy.

## 17. Rollback and recovery
| Situation | Action |
|---|---|
| A bad site deploy | Revert the merge commit on `main` (or redeploy the last good tag). Pages republishes in about 1 minute. The client degrades gracefully if the database is newer than the client. |
| A bad migration | Before every migration, `CREATE TABLE backup.<table>_<yyyymmdd> AS SELECT *` for each affected table. Apply the matching `supabase/rollback/` script, then restore rows from the backup schema if needed. Delete backups after 14 days. |
| Abuse or a vote flood | Set `voting_enabled = false` and/or `suggestions_enabled = false`, delete rows by IP-hash window if needed (counts are recomputed by trigger, or with `refresh_vote_counts()`), and add Turnstile under a new decision. Frozen dailies are unaffected. |
| An error in a published puzzle | Set `correction_note`; never edit the snapshot. Fix the catalog for future dates. |
| The freeze job missed a run | `get_daily` freezes lazily and logs `late_freeze`. The owner runs `select freeze_puzzle(d)` for any missing dates. Check `ops_log` daily during the soft launch. |
| Content pool exhausted or many categories flagged needs_clues | `pool_exhausted` is logged. Add clue sets or categories through a content PR. |
| Owner passphrase exposed | Set a new `owner_pass_hash` in `secrets`, then `owner_revoke_all`. |
| Supabase paused or down | The daily stays playable from the cache, with practice fallback. Restore the project from the Supabase dashboard, then check `ops_log` and run the freeze job manually. Move to Pro before promotion (D-21). |
| Analytics overload | Set `analytics_enabled = false`. The client queue drops quietly. |

## 18. Deferred (do not build)
- GOAT Battles and Predict the Crowd
- Settle the Debate
- Brackets
- Blind Résumé
- GOAT profiles
- Achievements beyond streaks
- Public SEO ranking pages
- Premium, ads and sponsored categories
- The iOS app
- Accounts and cross-device sync
- An analytics dashboard
- Turnstile (unless abuse appears)

## 19. Open items
| # | Item | Owner | Default |
|---|---|---|---|
| O-1 | Review and approve this document | ChatGPT, then Peter | (blocks the build) |
| O-2 | Puzzle #1 launch date (`config.launch_date`) | Peter | The first day after step 5 passes |
| O-3 | Contact email for privacy, deletion and corrections | Peter | (blocks `privacy.html`) |
| O-4 | Enable GitHub Pages: Settings → Pages → `main`, `/` root | Peter or ChatGPT | (blocks going live) |
| O-5 | Deliver ChatGPT's `categories.json` (36 categories) into the repo or chat | Peter | (blocks step 3) |
| O-6 | Optional custom domain | Peter | The github.io address |
