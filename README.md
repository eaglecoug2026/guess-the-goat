# The GOAT

Guess the crowd's greatest of all time.

**Play:** https://eaglecoug2026.github.io/guess-the-goat/

## Project docs

- [docs/PRODUCT.md](docs/PRODUCT.md): what the game is and its current state
- [docs/HANDOFF.md](docs/HANDOFF.md): MVP implementation spec (authoritative)
- [docs/ROADMAP.md](docs/ROADMAP.md): phases and deferred features
- [docs/DECISIONS.md](docs/DECISIONS.md): decision log

## How it plays

- **Daily GOAT**: one category a day. You get 5 guesses to find the crowd's #1. Each miss shows where your guess ranks in the crowd's top 10 (red hot, warm or cold). Names appear only once you type 2 letters, and you pick one from the list.
- **Hint and Give up**: Hint shows one clue at a time, up to 4. Give up (tap twice) ends the round and shows the answer; on the daily it counts as a loss. The share line says how many hints you used.
- **Hot Take Score**: after the reveal, you name your own GOAT. The score runs 0–100 by how far your pick is from the crowd. Results copy out as an emoji grid for sharing.
- **The debate**: after the reveal, each category has a message board. You type your GOAT (any name; one of the 16 also counts as your vote, and a last name alone is enough when only one of them has it), say why, and read everyone else's take. One take per player per category; posting again replaces it. Links and blocked words are refused, and the owner can hide any take. Each category starts with 3 starter takes, labeled as such. The board shows 5 takes at a time (yours on top) with a Show more button. Anyone can reply under a take (one level, 5 replies at a time), and you can edit your own take or reply; edited ones say so.
- **More GOATs**: broad groups (Sports, Movies, TV, Music, Food, and so on), then the categories in each group. Player positions sit one level deeper: Sports → NFL player → All, QB, RB, WR, TE, O-line, D-line, LB, DB (also NBA player and MLB player). Player-suggested crowd votes are under Crowd votes.
- **Player suggestions**: anyone can suggest a category. The owner reviews them and can add them to the game as live crowd votes.

## How it's built

- One static page (`index.html`) served by GitHub Pages. There's no build step.
- Back end: the Supabase project **The GOAT**. The page uses only the publishable key, and every write goes through a validated database function. Migrations, rollback scripts and SQL tests are in `supabase/`.
- Daily puzzles are frozen in the database ahead of time, so everyone gets the same puzzle for a date and a published puzzle never changes.
- Installable on phones: Share → Add to Home Screen gives a full-screen app with its own icon.

## Categories

- The content lives in `content/categories.json`: 68 categories, each with a `group`, an optional `family` (the middle level, e.g. NFL player) and a short `sub` name, 16 contenders, estimated percents for the top 10, and 4 clues for each of the top 3. Within a group, categories show in file order.
- Starter takes live in `content/takes.json` (3 per category).
- `npm run check:content` runs the checker (format, percents, clue length, and no clue that uses a word from its answer).
- `npm run build:content` regenerates `supabase/seed/catalog.sql`, `supabase/seed/takes.sql` and the bundled catalog in `index.html`. Run the SQL file in the Supabase SQL editor to load the changes. It updates categories by id, never changes a published puzzle, and retires (never deletes) a category removed from the file.
- Seasonal categories (Super Bowl snack, horror movie, Christmas movie) only run as the daily when they're scheduled in the owner panel.
- `content/FACT-CHECK.md` tracks the person check of every clue. `content/batches/` keeps ChatGPT's batches as sent, and `FIXES.md` lists every change made to them.

## Owner tools

Use **Owner sign-in** at the bottom of the page. A signed-in session lasts 12 hours and is kept only in that browser tab. The owner panel has the review queue, the latest takes (with Hide), live categories, the needs-clues list, the 30-day schedule, today's stats, corrections, player data deletion, and sign out everywhere.

Day-by-day numbers are on the **Site Stats** page on proctorpilot.com (The GOAT tab): new visitors, people who played and daily games finished. They come from `site_stats_daily` (migration 0008), which returns counts only and needs a token that only the ProctorPilot server holds. The same tab shows how people find the site on Google: it's in Google Search Console, verified by the `google-site-verification` tag in `index.html` (D-30), so keep that tag. Under the players it also shows who visits the website (visitors per day, city and county, how they got here, phone or computer): `visit.js` counts each page opened on proctorpilot.com, as daily totals only (D-35). The owner's own browsers are left out with the "leave this device out" link on that page, which also puts their player IDs on `site_stats_left_out` (migration 0012). A browser the link can't reach, like a home-screen icon, stops counting once its player ID is on that list: `visit.js` checks it once a day (`site_stats_is_left_out`, migration 0015, D-38). Crawlers aren't counted: `track()` stores nothing from a crawler's user agent, and `site_stats_daily` skips the crawler IDs on `site_stats_crawlers` (migration 0016, D-39). Add a scanner found later to that list with the reason.

To change the passphrase, run this in the Supabase SQL editor:

```sql
update public.secrets
set value = extensions.crypt('your-new-passphrase', extensions.gen_salt('bf', 10))
where key = 'owner_pass_hash';
```

## Tests

```
npm install
npx playwright install chromium webkit
npm test
```

- `tests/unit`: ranking math, tiers, Hot Take, puzzle numbers across DST, streaks, share text, and the category checker (Node, no browser).
- `tests/e2e`: Playwright in Chromium and WebKit at 390×844 and 1280×900, against an in-memory stand-in for the database (`tests/e2e/mock.mjs`). They never touch the live project.
- SQL tests for the database are in `supabase/tests`.
