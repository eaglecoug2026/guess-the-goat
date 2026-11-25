# The GOAT: roadmap

## Phase 0: prototype (done)
The daily game, Hot Take Score, Team GOAT, suggestions, owner review, community vote categories and the Supabase backend. See `PRODUCT.md`.

## Phase 1: MVP build (approved, waiting for Peter's "go")
Spec: `HANDOFF.md`. Build steps:
1. Backend migration and SQL tests
2. Page changes
3. Content import (12 converted + 36 new = 48 categories)
4. Privacy page, docs and Pages enabled
5. Pre-launch content fact-check sign-off

## Phase 2: soft launch
- Share with about 20–50 people.
- Review metrics after 7 days, then again at 30 days (`HANDOFF.md` §9):
  - Completion rate
  - % of completed games that produce a vote
  - D1 / D7 / D30 retention
  - Shares per completed game
  - % of referred visitors who complete their first game
- Upgrade to Supabase Pro before any substantial promotion.

## Decision gate after the soft launch
Choose the next priority based on the data:
| If the data shows… | Then prioritize… |
|---|---|
| Strong retention, weak sharing | Settle the Debate (shareable debates) |
| Strong sharing, short sessions | GOAT Battles and Predict the Crowd |
| Steady organic search traffic potential, rankings past 500 votes | Public SEO ranking pages |
| Weak retention | Fix the core loop before adding any mode |

## Deferred (explicitly out of MVP scope)
- GOAT Battles and Predict the Crowd
- Settle the Debate (user-created debates; needs moderation tooling)
- GOAT Brackets
- Blind Résumé
- GOAT personality profiles
- Achievements beyond the streak
- Public SEO ranking pages
- Premium membership, ads and sponsored categories
- iOS app (Capacitor wrap, push reminders, widget). Requires a name check first (see `DECISIONS.md` D-17).
- Accounts and cross-device sync
- Analytics dashboard (SQL reports only until then)

**Design constraint for all of these:** votes stay keyed by category + contender, so deferred modes can reuse MVP data.
