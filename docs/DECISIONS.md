# The GOAT: decision log

Each entry records what was decided, who agreed and why. **Status:** Accepted unless marked otherwise. Dates are 2026-11-25 unless noted. "C" = Claude, "G" = ChatGPT, "P" = Peter.

| ID | Decision | Agreed | Rationale |
|---|---|---|---|
| D-01 | Launch as a **website first**; the iOS app comes later | P, C | Link sharing drives growth, there's no store review, and updates are instant. The app will wrap the same code later. |
| D-02 | Host on **GitHub Pages** at `eaglecoug2026/guess-the-goat`, with the backend on **Supabase** | P, C | Free, static and simple. Supabase gives Postgres, RLS and RPC with no server to run. |
| D-03 | **MVP scope** = the daily game plus real votes, integrity, sharing, analytics and content. **Battles and other modes deferred.** | C, G | Validate that people return before adding modes. Personal GOAT votes solve the cold-start data problem without Battles. |
| D-04 | **Every personal GOAT pick is a real vote.** One per player per category, updatable. | G, C | Real data from day one. Known anchoring bias is accepted and documented. |
| D-05 | **Blended ranking** `(votes + k·e)/(total + k)`, where `e` is a decimal estimate and `k = 100` (configurable) | C, G | A smooth move from estimates to real votes, with no overnight jumps. |
| D-06 | **Disclosure tiers:** 0 = Estimated, 1–499 = Blended, 500+ = Community with estimated weighting disclosed. The vote count is always shown. | G, C | At 150 votes, estimates are still about 40% of the blend, so honesty requires labeling. |
| D-07 | **Clues for the top 3 contenders** (4 each). If the blended #1 has no clues, the category is skipped that day and flagged `needs_clues`. | C, G | Keeps clues correct as rankings change, at a manageable content cost. |
| D-08 | **Frozen daily puzzles.** Same date = same puzzle number, answer, ranking and clues worldwide. Never edited after publishing. | C, G | Fairness, shareability and resistance to manipulation. |
| D-09 | **Local-midnight reset** (the Wordle model) | C, G | A natural daily routine for players. |
| D-10 | **Freeze at least 48 hours ahead**, with DST-safe date math, and refresh when a player returns after midnight | G, C | Buffer for the earliest time zones and for operations. |
| D-11 | **Offline:** use a cached official puzzle only. If it's not cached, offer a practice round and **never present a different puzzle as the daily**. | G, C | The official daily must be identical for everyone. |
| D-12 | **Outages don't break streaks.** Duplicate votes are prevented with idempotent upserts. | G, C | Players shouldn't be penalized for our failures. |
| D-13 | **Owner auth** = passphrase exchanged for a secure random 12-hour token: hashed in the database, kept in sessionStorage, revocable, with login rate limits | C, G | Proportionate for the MVP. No credentials are stored in the browser. |
| D-14 | **Vote integrity** = generous IP-hash rate limits, one vote row per player per category, frozen puzzles and monitoring. **Turnstile only if abuse appears.** | C, G | No friction for casual players. Shared IPs (schools, carriers) must not be blocked. |
| D-15 | **Pending suggestions are private.** The public sees approved categories only. | C, G | Prevents offensive public text. |
| D-16 | **Server-side vote counts** (trigger-maintained) | C, G | Downloading every vote row doesn't scale. |
| D-17 | Check the name "GOAT" against the existing sneaker brand **before the App Store**; not a web-launch blocker | C | Trademark risk for app naming. |
| D-18 | **Sharing is spoiler-free by default**, with an optional "include my pick". The share has the URL with an anonymous referral code, the puzzle number, and native share with clipboard fallback. | C, G | Growth loop without spoilers. The referral code contains no personal data. |
| D-19 | **First-party analytics only.** No cookies, no third-party trackers, events from an allowlist. SQL reports first, dashboard later. | C, G | Privacy-light, and retention can be measured with the anonymous ID. |
| D-20 | **Colorblind-safe indicators are P0.** Rank numbers and words always accompany colors. | G, C | Accessibility is a launch requirement. |
| D-21 | **Supabase Pro** is required before substantial promotion, not for the soft launch | G, C | Cost only when it's justified. |
| D-22 | **Rejected for now:** selling aggregated preference data; ads at launch | C, G | Privacy law, trust, and too little data to be worth it. To be revisited only with a privacy policy and scale. |
| D-23 | **Roles:** Claude owns code, database and deploys. ChatGPT owns content and independent review. Peter approves and merges. | P, C, G | Clear ownership. One repo is the source of truth. |
| D-24 | **Content format** = `content/categories.json` with 16 contenders, top 10 with whole-% estimates in descending order, and clues for the top 3. Must pass the validator script before import. | C, G | Repeatable content pipeline. |
| D-25 | **Rate limits key on the address Cloudflare sets** (`cf-connecting-ip`, else the last `x-forwarded-for` entry), not the first `x-forwarded-for` entry. Amends HANDOFF §6.4. | P, C | Verified live on 2026-11-25: the first entry is whatever the client sends, so rotating a fake header bypassed every limit, including owner login. Cloudflare rejects client-set `cf-connecting-ip`. Implemented in migration 0007. |
| D-26 | **Before launch day, the daily slot says when Daily GOAT #1 starts and offers practice rounds.** Applies while `config.launch_date` is unset or later than the local date. No streak or excused date is recorded. | P, C | The site went live early (O-4, 2026-11-25), before content and `launch_date` (O-2). Without this, every visitor would see the "can't load" notice. |
| D-27 | **Launched 2026-11-25, before the pre-launch gate (step 5).** `launch_date` = 2026-11-25; puzzles #1-#4 frozen the same day (action movie star, BBQ food, Best Picture winner, board game). The person fact-check, ChatGPT's review of Claude's clues and the iPhone test happen after launch. | P | Peter's call ("now, why wait"). Every clue passed the checker and Claude's first read. A clue error found later can be corrected for frozen puzzles with a correction note, and fixed in the catalog for future ones. |
