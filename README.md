# The GOAT

Guess the crowd's greatest of all time.

**Play:** https://eaglecoug2026.github.io/guess-the-goat/

## How it plays

- **Daily GOAT**: one category a day. You get 5 guesses to find the crowd's #1. Each miss shows where your guess ranks in the crowd's top 10 (red hot, warm or cold) and unlocks a clue.
- **Hot Take Score**: after the reveal, you name your own GOAT. The score runs 0–100 by how far your pick is from the crowd. Results copy out as an emoji grid for sharing.
- **Team GOAT**: 8 random categories dealt from the pool, with a Shuffle button.
- **Player suggestions**: anyone can suggest a category. The owner reviews them and can add them to the game as live crowd votes.

## How it's built

- One static page (`index.html`) served by GitHub Pages. There's no build step.
- Suggestions, votes and added categories live in the Supabase project **The GOAT** (Intellismart org).
  - The public key in the page can only read, and can only write through validated database functions (`suggest`, `cast_vote`).
  - Owner actions (`review_suggestion`, `remove_category`) require the owner passphrase.
- Installable on phones: Share → Add to Home Screen gives a full-screen app with its own icon.

## Owner tools

Use **Owner sign-in** at the bottom of the page. Owner mode turns on the review queue, where you can add, edit, dismiss or remove categories.

To change the passphrase, run this in the Supabase SQL editor:

```sql
update public.owner_secret
set pass_hash = extensions.crypt('your-new-passphrase', extensions.gen_salt('bf', 10))
where id = 1;
```

## Editing categories

Built-in categories are in the `CATS` array near the top of the script in `index.html`. Each one has 16 contenders, crowd percentages for the top 10, and 4 clues ordered from vague to obvious. The crowd numbers are sample data for now.
