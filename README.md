# The GOAT

Guess the crowd's greatest of all time.

**Play:** https://eaglecoug2026.github.io/guess-the-goat/

## Project docs

- [docs/PRODUCT.md](docs/PRODUCT.md): what the game is and its current state
- [docs/HANDOFF.md](docs/HANDOFF.md): MVP implementation spec (authoritative)
- [docs/ROADMAP.md](docs/ROADMAP.md): phases and deferred features
- [docs/DECISIONS.md](docs/DECISIONS.md): decision log

## How it plays

- **Daily GOAT**: one category a day. You get 5 guesses to find the crowd's #1. Each miss shows where your guess ranks in the crowd's top 10 (red hot, warm or cold). No clues are shown. Names appear only once you type 2 letters, and you pick one from the list.
- **Hot Take Score**: after the reveal, you name your own GOAT. The score runs 0–100 by how far your pick is from the crowd. Results copy out as an emoji grid for sharing.
- **Team GOAT**: 8 random categories dealt from the pool, with a Shuffle button.
- **Player suggestions**: anyone can suggest a category. The owner reviews them and can add them to the game as live crowd votes.

## How it's built

- One static page (`index.html`) served by GitHub Pages. There's no build step.
- Back end: the Supabase project **The GOAT**. The page uses only the publishable key, and every write goes through a validated database function. Migrations, rollback scripts and SQL tests are in `supabase/`.
- Daily puzzles are frozen in the database ahead of time, so everyone gets the same puzzle for a date and a published puzzle never changes.
- Installable on phones: Share → Add to Home Screen gives a full-screen app with its own icon.

## Categories

- The content lives in `content/categories.json`: 48 categories, each with 16 contenders, estimated percents for the top 10, and 4 clues for each of the top 3.
- `npm run check:content` runs the checker (format, percents, clue length, and no clue that uses a word from its answer).
- `npm run build:content` regenerates `supabase/seed/catalog.sql` and the bundled catalog in `index.html`. Run the SQL file in the Supabase SQL editor to load the changes. It updates categories by id, never changes a published puzzle, and retires (never deletes) a category removed from the file.
- Seasonal categories (Super Bowl snack, horror movie, Christmas movie) only run as the daily when they're scheduled in the owner panel.
- `content/FACT-CHECK.md` tracks the person check of every clue. `content/batches/` keeps ChatGPT's batches as sent, and `FIXES.md` lists every change made to them.

## Owner tools

Use **Owner sign-in** at the bottom of the page. A signed-in session lasts 12 hours and is kept only in that browser tab. The owner panel has the review queue, live categories, the needs-clues list, the 30-day schedule, today's stats, corrections, player data deletion, and sign out everywhere.

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
