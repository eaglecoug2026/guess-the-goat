# Fixes to apply when the batches are combined into content/categories.json

The batch files are kept exactly as ChatGPT sent them. Changes are made in the combined file only.

## All batches
- Titles: lowercase after "GOAT" unless it's a proper noun, to match the existing 12 (e.g. "GOAT rock band", "GOAT NFL quarterback", "GOAT Disney animated movie").

## Batch 1
- nfl-quarterback: Peter 2026-11-25: Joe Montana is the clear #1. Swap the top two: Joe Montana 39, Tom Brady 17 (Montana listed first). Everyone else unchanged, so the top 3 with clues are still Montana, Brady, Mahomes.
- comedy-actor / Robin Williams, clue 3: "Good Hunting" is wrong; the film is Good Will Hunting. ("Will" is allowed: the rule bans words from the contender's own name, and "Williams" isn't "Will".) Use: "Won an Oscar for Good Will Hunting, directed by Gus Van Sant."

## Batch 2
- cartoon-series / Looney Tunes, clue 2: Warner Bros. released the original shorts; Leon Schlesinger's studio made them until Warner bought it in 1944. Use: "Warner Bros. released the original theatrical cartoons."

## Batch 3
- bbq-food / Baby Back Ribs, clue 4: "spareribs" contains "ribs", a word from the answer (the checker caught it). Use: "Cut from the loin, its bones are shorter than the belly-side cut."

## The 12 originals (originals.json)
- Converted from the old built-in list: estimates to whole percents, same order.
- Claude wrote the #2 and #3 clue sets (HANDOFF §12) and Wikipedia sources for every clued contender. ChatGPT reviews them.
- Three old #1 clues broke the name rule and were reworded: Zelda clue 3 ("time"), Cinnamon Toast Crunch clue 4 ("cinnamon"), Reese's clues 3-4 ("cups", "peanut", "butter").

## NFL positions (nfl-positions.json, 2026-11-27)
- Written by Claude at Peter's request ("NFL then sub QB WR DB Oline D Line, RB"), not by ChatGPT. Kept as written except one J.J. Watt clue, softened from "the only player with two seasons of 20 or more sacks" to "Had two seasons with 20 or more sacks" (the "only" may not hold after 2025).
- Starter takes (`content/takes.json`) were also written by Claude: 159 takes, 9 of them write-ins.
