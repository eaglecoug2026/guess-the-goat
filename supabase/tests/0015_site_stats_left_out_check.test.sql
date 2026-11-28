-- SQL tests for 0015_site_stats_left_out_check.sql. One transaction, rolled back; the test player IDs never
-- reach the real list.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

insert into public.site_stats_left_out (player) values ('check-test-owner') on conflict do nothing;

-- ---------- as anon, the way visit.js calls it
set local role anon;
select pg_temp.ok('a player on the list -> true', (select public.site_stats_is_left_out('check-test-owner')) is true);
select pg_temp.ok('a player not on the list -> false', (select public.site_stats_is_left_out('check-test-other')) is false);
select pg_temp.ok('no player ID -> false', (select public.site_stats_is_left_out(null)) is false);
select pg_temp.ok('anon still cannot read the list', pg_temp.err('select * from public.site_stats_left_out') like 'permission denied%');
select pg_temp.ok('anon still cannot add to the list',
  pg_temp.err($q$insert into public.site_stats_left_out (player) values ('check-test-other')$q$) like 'permission denied%');
reset role;

-- ---------- signed-in roles get nothing new
set local role authenticated;
select pg_temp.ok('authenticated cannot call it', pg_temp.err($q$select public.site_stats_is_left_out('check-test-owner')$q$) like 'permission denied%');
reset role;

select pg_temp.ok('the check stored nothing', (select count(*) = 1 from public.site_stats_left_out where player like 'check-test-%'));

select test, ok, detail from _r order by at;
rollback;
