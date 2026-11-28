-- SQL tests for 0012_site_stats_leave_me_out.sql. One transaction, rolled back. Synthetic events are dated
-- 2001 so they never mix with real data. Throwaway token and code hashes are swapped in inside the
-- transaction only; the real ones are never used, printed or stored.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

insert into public.secrets (key, value) values
  ('site_stats_token_sha256', encode(sha256(convert_to('goat-stats-test-token', 'UTF8')), 'hex')),
  ('site_stats_leave_out_sha256', encode(sha256(convert_to('goat-leave-out-test-code', 'UTF8')), 'hex'))
on conflict (key) do update set value = excluded.value;

-- 2001-06-01, Pacific: the owner and player B both visit and play the daily; the owner finishes it.
insert into public.events (event_id, at, player, event, puzzle_no, props) values
 (gen_random_uuid(), '2001-06-01 17:00+00', 'stats-test-owner', 'visit', null, '{}'),
 (gen_random_uuid(), '2001-06-01 17:01+00', 'stats-test-owner', 'game_start', 1, '{}'),
 (gen_random_uuid(), '2001-06-01 17:05+00', 'stats-test-owner', 'game_complete', 1, '{"won": true, "guesses": 2}'),
 (gen_random_uuid(), '2001-06-01 18:00+00', 'stats-test-b', 'visit', null, '{}'),
 (gen_random_uuid(), '2001-06-01 18:01+00', 'stats-test-b', 'game_start', 1, '{}');

-- ---------- as anon, the way visit.js and the ProctorPilot server call it
set local role anon;
create temp table _before on commit drop as
  select public.site_stats_daily('goat-stats-test-token', '2001-06-01', '2001-06-01') as r;
select pg_temp.ok('no code -> not allowed', pg_temp.err($q$select public.site_stats_leave_me_out(null, 'stats-test-owner')$q$) = 'not allowed');
select pg_temp.ok('wrong code -> not allowed', pg_temp.err($q$select public.site_stats_leave_me_out('nope', 'stats-test-owner')$q$) = 'not allowed');
select pg_temp.ok('player ID too short -> bad_input', pg_temp.err($q$select public.site_stats_leave_me_out('goat-leave-out-test-code', 'short')$q$) = 'bad_input');
select pg_temp.ok('anon cannot read the left-out list', pg_temp.err('select * from public.site_stats_left_out') like 'permission denied%');
select pg_temp.ok('anon cannot add to the list directly',
  pg_temp.err($q$insert into public.site_stats_left_out (player) values ('stats-test-b')$q$) like 'permission denied%');
select pg_temp.ok('the right code leaves the owner out',
  (select public.site_stats_leave_me_out('goat-leave-out-test-code', 'stats-test-owner')) = '{"ok": true}'::jsonb);
select pg_temp.ok('a second time is fine',
  (select public.site_stats_leave_me_out('goat-leave-out-test-code', 'stats-test-owner')) = '{"ok": true}'::jsonb);
create temp table _after on commit drop as
  select public.site_stats_daily('goat-stats-test-token', '2001-06-01', '2001-06-01') as r;
reset role;

select pg_temp.ok('before: 2 new visitors, 2 visitors, 2 played, 1 finished',
  (select r -> 'days' -> 0 from _before) = '{"date": "2001-06-01", "new_visitors": 2, "visitors": 2, "played": 2, "finished": 1}'::jsonb,
  (select (r -> 'days' -> 0)::text from _before));
select pg_temp.ok('after: only player B is counted',
  (select r -> 'days' -> 0 from _after) = '{"date": "2001-06-01", "new_visitors": 1, "visitors": 1, "played": 1, "finished": 0}'::jsonb,
  (select (r -> 'days' -> 0)::text from _after));
select pg_temp.ok('after: totals skip the owner too',
  (select r -> 'new_visitors' = '1' and r -> 'visitors' = '1' and r -> 'played' = '1' and r -> 'finished' = '0'
          and r -> 'visitors_total' = '1' from _after),
  (select r::text from _after));
select pg_temp.ok('the owner is on the list once', (select count(*) = 1 from public.site_stats_left_out where player = 'stats-test-owner'));
select pg_temp.ok('the owner''s events are still there', (select count(*) = 3 from public.events where player = 'stats-test-owner'));
select pg_temp.ok('no player IDs in the answer', (select position('stats-test' in r::text) = 0 from _after));

select test, ok, detail from _r order by at;
rollback;
