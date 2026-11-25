# SQL tests

One file per migration (`NNNN_<name>.test.sql`). Each file is self-contained: it opens a transaction,
sets up its own fixtures, runs every check, prints one row per check (`test`, `ok`, `detail`) and
**rolls back**, so nothing persists.

- Checks run as `postgres` for setup and as `anon` (`set local role anon`) for the public API, with
  `request.headers` set to simulate the caller's `x-forwarded-for`.
- Owner flows log in through `owner_login` with a throwaway passphrase whose hash is swapped in inside
  the transaction only. The real owner passphrase is never used, printed or stored.
- Freeze logic uses 2099 dates and a mocked `launch_date`, so real puzzles are never touched.

Run a file in the Supabase SQL editor (or via the Supabase connector's `execute_sql`) against project
`mzlbnsibalthsycmvshm`. All rows must have `ok = true`.
