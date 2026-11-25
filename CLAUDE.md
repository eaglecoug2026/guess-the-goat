# Instructions for Claude sessions in this repo

- Read `docs/HANDOFF.md` before changing anything. It is the authoritative MVP spec. Context lives in `docs/PRODUCT.md`, `docs/ROADMAP.md` and `docs/DECISIONS.md`.
- Build only what HANDOFF.md specifies. Any change of scope needs a new entry in DECISIONS.md, agreed by Peter.
- Work on one branch per HANDOFF §13 step and open a PR. Peter merges. Never push straight to `main`.
- Database changes: commit the migration in `supabase/migrations/` along with its rollback script and SQL tests, back up the affected tables first, then apply it to project `mzlbnsibalthsycmvshm` and run the security advisor.
- Never commit secrets. Only the Supabase publishable key belongs in the client. The owner passphrase must never be committed or stored in the browser.
- A published `daily_puzzles` row is never edited.
