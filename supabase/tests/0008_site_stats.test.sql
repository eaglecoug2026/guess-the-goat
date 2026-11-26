-- SQL tests for 0008_site_stats.sql. One transaction, rolled back. Synthetic events are dated 2001 so they
-- never mix with real data. A throwaway token's hash is swapped in inside the transaction only.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

insert into public.secrets (key, value)
values ('site_stats_token_sha256', encode(sha256(convert_to('goat-stats-test-token', 'UTF8')), 'hex'))
on conflict (key) do update set value = excluded.value;

-- 2001-06-01 and 06-02, Pacific: player A visits and plays the daily on day 1 (finishes it), comes back
-- day 2 for practice; player B only visits day 2; player C visits late on 06-02 Pacific (06-03 UTC).
insert into public.events (event_id, at, player, event, puzzle_no, props) values
 (gen_random_uuid(), '2001-06-01 17:00+00', 'stats-test-a', 'visit', null, '{}'),
 (gen_random_uuid(), '2001-06-01 17:01+00', 'stats-test-a', 'game_start', 1, '{}'),
 (gen_random_uuid(), '2001-06-01 17:05+00', 'stats-test-a', 'game_complete', 1, '{"won": true, "guesses": 2}'),
 (gen_random_uuid(), '2001-06-01 17:06+00', 'stats-test-a', 'game_complete', 1, '{"won": true, "guesses": 2}'),
 (gen_random_uuid(), '2001-06-02 18:00+00', 'stats-test-a', 'practice_start', null, '{}'),
 (gen_random_uuid(), '2001-06-02 18:30+00', 'stats-test-b', 'visit', null, '{}'),
 (gen_random_uuid(), '2001-06-03 05:00+00', 'stats-test-c', 'visit', null, '{}');

-- ---------- as anon, the way the ProctorPilot server calls it
set local role anon;
select pg_temp.ok('no token -> not allowed', pg_temp.err($q$select public.site_stats_daily(null, '2001-06-01', '2001-06-02')$q$) = 'not allowed');
select pg_temp.ok('wrong token -> not allowed', pg_temp.err($q$select public.site_stats_daily('nope', '2001-06-01', '2001-06-02')$q$) = 'not allowed');
select pg_temp.ok('end before start -> bad date range', pg_temp.err($q$select public.site_stats_daily('goat-stats-test-token', '2001-06-02', '2001-06-01')$q$) = 'bad date range');
select pg_temp.ok('over 800 days -> bad date range', pg_temp.err($q$select public.site_stats_daily('goat-stats-test-token', '2001-01-01', '2003-12-31')$q$) = 'bad date range');
select pg_temp.ok('anon still cannot read events', pg_temp.err('select * from public.events') like 'permission denied%');
select pg_temp.ok('anon cannot read secrets', pg_temp.err('select * from public.secrets') like 'permission denied%');

create temp table _s on commit drop as
  select public.site_stats_daily('goat-stats-test-token', '2001-06-01', '2001-06-02') as r;
reset role;

select pg_temp.ok('two Pacific days, in order',
  (select jsonb_agg(d ->> 'date') from _s, jsonb_array_elements(r -> 'days') d) = '["2001-06-01", "2001-06-02"]'::jsonb);
select pg_temp.ok('day 1: 1 new visitor, 1 visitor, 1 played, 1 daily finished (a resent finish counts once)',
  (select r -> 'days' -> 0 from _s) = '{"date": "2001-06-01", "new_visitors": 1, "visitors": 1, "played": 1, "finished": 1}'::jsonb,
  (select (r -> 'days' -> 0)::text from _s));
select pg_temp.ok('day 2 (Pacific): B and C are new, A came back to practice',
  (select r -> 'days' -> 1 from _s) = '{"date": "2001-06-02", "new_visitors": 2, "visitors": 3, "played": 1, "finished": 0}'::jsonb,
  (select (r -> 'days' -> 1)::text from _s));
select pg_temp.ok('totals for the range',
  (select r -> 'new_visitors' = '3' and r -> 'visitors' = '3' and r -> 'played' = '1' and r -> 'finished' = '1' from _s),
  (select r::text from _s));
select pg_temp.ok('no player IDs in the answer', (select position('stats-test' in r::text) = 0 from _s));

select test, ok, detail from _r order by at;
rollback;
