# The GOAT: product

## What it is
A daily web game about "Greatest Of All Time" debates. Players try to find the **crowd's** #1 pick in a category in 5 guesses, then name their own GOAT and get a **Hot Take Score** for how far they are from the crowd. It's designed to spread through shared results, the way Wordle did.

**Live (once Pages is enabled):** https://eaglecoug2026.github.io/guess-the-goat/
**Owner:** Peter (eaglecoug2026). **Build:** Claude. **Content and review:** ChatGPT.

## Principles
1. The daily game comes first. Everything else is secondary on screen.
2. No sign-up to play. Players are anonymous by default.
3. Be honest about data. Estimated and blended rankings are always labeled, with the real vote count shown.
4. A published puzzle never changes.
5. Privacy-light: no ads, no third-party trackers, no selling data.
6. Ship small, measure, then expand. Expansion is decided by soft-launch data.

## Current functionality (as of commit `21cee75`, before the MVP build)
- **Daily GOAT:** one category per day, picked by the date and the category list (to be replaced). 5 guesses. Each miss shows the guess's crowd rank, its %, and a heat color. Clues unlock 1 → 4 for the #1 answer only.
- **Reveal:** the crowd's top-10 bars, with the player's guesses outlined.
- **Personal GOAT and Hot Take Score:** `round(100 × (1 − pick% / top%))`. Labels: 0 Consensus king, 1–40 Mild take, 41–75 Spicy take, 76–99 Hot take, 100 Certified contrarian. The pick is saved **locally only**.
- **Share:** copies an emoji grid plus the player's pick. **No URL and no puzzle number** (to be fixed).
- **Team GOAT:** 8 random categories from 12 built-ins, with Shuffle. Practice rounds don't count toward stats.
- **Stats:** streak, played and win % in localStorage, daily only. The streak doesn't visually reset after a missed day (to be fixed).
- **Player suggestions:** a form calls the `suggest` RPC. **Pending suggestions are publicly readable** (to be fixed).
- **Owner review:** passphrase sign-in using `check_owner`. The passphrase is **stored in localStorage** (to be fixed). The owner can add (edit contenders, min 4), dismiss, or remove categories.
- **Community vote categories:** added suggestions become vote-only categories. Votes go through the `cast_vote` RPC. **Tallies are computed in the browser by downloading every vote row** (to be fixed).
- **Installable:** web manifest, home-screen icons and iOS meta tags.
- **Content:** 12 built-in categories with **sample** estimated percentages, 16 contenders each, and 4 clues for the #1 only.

## Current architecture
- **Front end:** a single static `index.html` (HTML, CSS and vanilla JS, no build step). Fonts are Anton and Inter from Google Fonts. Hosted on GitHub Pages from `main` at the root.
- **Back end:** Supabase project **The GOAT** (`mzlbnsibalthsycmvshm`, us-west-1, free tier).
  - The client calls PostgREST directly with the publishable key: `GET` on tables and `POST /rpc/*`.
  - Tables: `suggestions`, `categories`, `votes`, `owner_secret`.
  - Functions: `suggest`, `cast_vote`, `check_owner`, `review_suggestion`, `remove_category`. All are `SECURITY DEFINER` with `search_path = ''`.
  - RLS is on everywhere. Public writes happen only through functions. Voter-ID columns and the owner secret are not readable by the public.
- **Identity:** a random voter ID in localStorage (`goat-voter`).
- **Prototype:** a separate Claude-hosted artifact version exists. It's a prototype only and **not maintained**. This repo is the source of truth.

## Visual identity
Trophy-gold ground (`#f6c519`), a black scoreboard board (`#18140f`), cream cards, a red accent (`#e5372b`), Anton for headlines, Inter for body text, and a crowned goat mascot drawn as an inline SVG.

## Related docs
- `docs/HANDOFF.md`: implementation spec for the MVP build (authoritative)
- `docs/ROADMAP.md`: phases and what's deferred
- `docs/DECISIONS.md`: decision log with rationale
