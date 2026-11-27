-- SQL tests for 0011_last_name_picks.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

insert into public.catalog (slug, name, title, kind, opts, source, grp, sub) values
 ('test-l', 'Test L', 'GOAT test L', 'daily',
  '[{"name":"Michael Jordan","est":0.3},{"name":"Floyd Mayweather Jr.","est":0.2},{"name":"Tim Brown","est":0.1},{"name":"Antonio Brown","est":0.1},
    {"name":"Brown","est":0.1},{"name":"Half-Life 2","est":0.1},{"name":"Jordan Love","est":0.05},{"name":"Le Ng","est":0.05}]',
  'builtin', 'Testing', 'L');

select pg_temp.ok('last name alone -> the contender', public.match_pick('test-l', 'Jordan') = 'Michael Jordan');
select pg_temp.ok('any case and spaces', public.match_pick('test-l', '  jORDAN ') = 'Michael Jordan');
select pg_temp.ok('Jr. is skipped', public.match_pick('test-l', 'mayweather') = 'Floyd Mayweather Jr.');
select pg_temp.ok('the suffix itself does not match', public.match_pick('test-l', 'Jr.') is null);
select pg_temp.ok('exact name still wins: one-word contender Brown', public.match_pick('test-l', 'brown') = 'Brown');
select pg_temp.ok('full name still matches', public.match_pick('test-l', 'tim brown') = 'Tim Brown');
select pg_temp.ok('first name alone is a write-in', public.match_pick('test-l', 'Michael') is null);
select pg_temp.ok('a number alone is a write-in', public.match_pick('test-l', '2') is null);
select pg_temp.ok('two words that are not a name are a write-in', public.match_pick('test-l', 'Air Jordan') is null);
select pg_temp.ok('short last name works', public.match_pick('test-l', 'ng') = 'Le Ng');
select pg_temp.ok('unknown category -> null', public.match_pick('no-such-cat', 'Jordan') is null);
select pg_temp.ok('empty -> null', public.match_pick('test-l', '  ') is null);
update public.catalog set opts = opts || '[{"name":"DeAndre Jordan","est":0}]' where slug = 'test-l';
select pg_temp.ok('two contenders share the last name -> write-in', public.match_pick('test-l', 'Jordan') is null);
update public.catalog set opts = opts - (jsonb_array_length(opts) - 1) where slug = 'test-l';

select set_config('request.headers', '{"x-forwarded-for":"203.0.113.111"}', true);
set local role anon;
select pg_temp.ok('anon cannot call match_pick', pg_temp.err($q$select public.match_pick('test-l', 'Jordan')$q$) like 'permission denied%');
select pg_temp.ok('post_take: a last name is stored as the full name and counts as the vote',
  (select p -> 'take' ->> 'pick' = 'Michael Jordan' and p ->> 'pick' = 'Michael Jordan' and (p ->> 'voted')::boolean
     from (select public.post_take('player-l11-0001', 'test-l', 'jordan', 'Six rings, no contest.') p) x));
select pg_temp.ok('post_take: a name not on the list stays a write-in',
  (select p -> 'take' ->> 'pick' = 'Williams' and p -> 'pick' = 'null'::jsonb and not (p ->> 'voted')::boolean
     from (select public.post_take('player-l11-0002', 'test-l', 'Williams', 'Not on the list here.') p) x));
reset role;
select pg_temp.ok('the vote landed on the full name',
  exists (select 1 from public.catalog_votes where slug = 'test-l' and player = 'player-l11-0001' and pick = 'Michael Jordan'));
select pg_temp.ok('no vote for the write-in',
  not exists (select 1 from public.catalog_votes where slug = 'test-l' and player = 'player-l11-0002'));

select test, ok, detail from _r order by at;
rollback;
