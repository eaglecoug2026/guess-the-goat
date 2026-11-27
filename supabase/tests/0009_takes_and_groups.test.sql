-- SQL tests for 0009_takes_and_groups.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
create temp table _tok (name text primary key, token text) on commit drop;
grant all on _r, _tok to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

update public.secrets set value = extensions.crypt('goat-test-pass-1', extensions.gen_salt('bf', 4)) where key = 'owner_pass_hash';
insert into public.secrets (key, value) values ('blocked_words', 'zzbadword,qqrude') on conflict (key) do update set value = excluded.value;
insert into public.catalog (slug, name, title, kind, opts, source, grp, sub) values
 ('test-t', 'Test T', 'GOAT test T', 'daily', '[{"name":"Wé Al","est":0.5},{"name":"X","est":0.3},{"name":"Y","est":0.2},{"name":"Z","est":0}]', 'builtin', 'Testing', 'T');
insert into public.takes (slug, author, pick, reason, seed) values ('test-t', 'Starter Sam', 'X', 'Seeded reason here.', true);

-- ---------- groups
select pg_temp.ok('get_catalog returns grp and sub',
  (select e ->> 'grp' = 'Testing' and e ->> 'sub' = 'T' from jsonb_array_elements(public.get_catalog()) e where e ->> 'slug' = 'test-t'));

-- ---------- posting
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.90"}', true);
set local role anon;
select pg_temp.ok('anon cannot select takes', pg_temp.err('select * from public.takes') like 'permission denied%');
select pg_temp.ok('post a take that matches a contender (any case)',
  (select p -> 'take' ->> 'pick' = 'Wé Al' and (p ->> 'voted')::boolean and p ->> 'pick' = 'Wé Al' and (p -> 'take' ->> 'mine')::boolean
     from (select public.post_take('player-t9-0001', 'test-t', '  wé   al ', 'Best   ever, no contest.', 'Pat') p) x));
reset role;
select pg_temp.ok('matching pick also counts as the vote',
  exists (select 1 from public.catalog_votes where slug = 'test-t' and player = 'player-t9-0001' and pick = 'Wé Al'));
set local role anon;
select pg_temp.ok('posting again replaces the take (write-in, no vote)',
  (select p -> 'take' ->> 'pick' = 'Somebody Else' and not (p ->> 'voted')::boolean and p ->> 'pick' is null
     from (select public.post_take('player-t9-0001', 'test-t', 'Somebody Else', 'Changed my mind.') p) x));
reset role;
select pg_temp.ok('one take per player per category', (select count(*) = 1 from public.takes where player = 'player-t9-0001'));
select pg_temp.ok('vote kept after a write-in take', exists (select 1 from public.catalog_votes where slug = 'test-t' and player = 'player-t9-0001'));
set local role anon;
select pg_temp.ok('link -> blocked', pg_temp.err($q$select public.post_take('player-t9-0002', 'test-t', 'X', 'see www.example.com')$q$) = 'blocked');
select pg_temp.ok('bare domain -> blocked', pg_temp.err($q$select public.post_take('player-t9-0002', 'test-t', 'X', 'go to spam.io now')$q$) = 'blocked');
select pg_temp.ok('blocked word (any case) -> blocked', pg_temp.err($q$select public.post_take('player-t9-0002', 'test-t', 'X', 'what a ZZBADWORD take')$q$) = 'blocked');
select pg_temp.ok('blocked word in the name -> blocked', pg_temp.err($q$select public.post_take('player-t9-0002', 'test-t', 'X', 'fine reason', 'qqrude guy')$q$) = 'blocked');
select pg_temp.ok('a word containing a blocked word is fine', pg_temp.err($q$select public.post_take('player-t9-0002', 'test-t', 'X', 'xzzbadwordx is not a word')$q$) = 'ok');
select pg_temp.ok('empty reason -> bad_input', pg_temp.err($q$select public.post_take('player-t9-0003', 'test-t', 'X', '   ')$q$) = 'bad_input');
select pg_temp.ok('281-char reason -> bad_input', pg_temp.err(format($q$select public.post_take('player-t9-0003', 'test-t', 'X', %L)$q$, repeat('a', 281))) = 'bad_input');
select pg_temp.ok('41-char pick -> bad_input', pg_temp.err(format($q$select public.post_take('player-t9-0003', 'test-t', %L, 'ok reason')$q$, repeat('a', 41))) = 'bad_input');
select pg_temp.ok('25-char name -> bad_input', pg_temp.err(format($q$select public.post_take('player-t9-0003', 'test-t', 'X', 'ok reason', %L)$q$, repeat('a', 25))) = 'bad_input');
select pg_temp.ok('unknown category -> bad_input', pg_temp.err($q$select public.post_take('player-t9-0003', 'nope-nope', 'X', 'ok reason')$q$) = 'bad_input');
select pg_temp.ok('short player id -> bad_input', pg_temp.err($q$select public.post_take('short', 'test-t', 'X', 'ok reason')$q$) = 'bad_input');

-- ---------- reading
select pg_temp.ok('get_takes: player takes first, then starter takes; no player ids',
  (select g -> 'takes' -> 0 ->> 'seed' = 'false' and g -> 'takes' -> -1 ->> 'author' = 'Starter Sam'
          and (g -> 'takes' -> -1 ->> 'seed')::boolean and (g ->> 'total')::int = 3
          and not (g::text like '%player-t9%')
     from (select public.get_takes('test-t', 'player-t9-0001') g) x));
select pg_temp.ok('mine flag only for the asking player',
  (select count(*) filter (where (t ->> 'mine')::boolean) = 1 from jsonb_array_elements(public.get_takes('test-t', 'player-t9-0001') -> 'takes') t));
select pg_temp.ok('get_takes with no player works', (select (public.get_takes('test-t') ->> 'total')::int = 3));
reset role;

-- ---------- owner
insert into _tok values ('a', (select public.owner_login('goat-test-pass-1')));
set local role anon;
select pg_temp.ok('owner_takes needs a token', pg_temp.err($q$select public.owner_takes('bad-token')$q$) = 'not_owner');
select pg_temp.ok('owner_takes lists player takes only',
  (select jsonb_array_length(o) = (select count(*) from jsonb_array_elements(o) e where e ->> 'seed' = 'false')
     from (select public.owner_takes((select token from _tok where name = 'a')) o) x));
select pg_temp.ok('owner hides a take',
  pg_temp.err(format($q$select public.owner_hide_take(%L, %s, true)$q$, (select token from _tok where name = 'a'),
    (select (t ->> 'id') from jsonb_array_elements(public.get_takes('test-t', 'player-t9-0002') -> 'takes') t where (t ->> 'mine')::boolean))) = 'ok');
select pg_temp.ok('hidden take is gone for others but kept for its author',
  (select (public.get_takes('test-t') ->> 'total')::int = 2
      and exists (select 1 from jsonb_array_elements(public.get_takes('test-t', 'player-t9-0002') -> 'takes') t where (t ->> 'mine')::boolean and (t ->> 'hidden')::boolean)));
select pg_temp.ok('owner_delete_player deletes takes',
  (select (d ->> 'takes')::int = 1 from (select public.owner_delete_player((select token from _tok where name = 'a'), 'player-t9-0001') d) x));
reset role;

-- ---------- switches and limits
update public.config set value = 'false' where key = 'takes_enabled';
set local role anon;
select pg_temp.ok('takes_enabled = false -> disabled', pg_temp.err($q$select public.post_take('player-t9-0004', 'test-t', 'X', 'ok reason')$q$) = 'disabled');
reset role;
update public.config set value = 'true' where key = 'takes_enabled';
update public.config set value = jsonb_set(value, '{take,limit}', '2') where key = 'rate_limits';
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.91"}', true);
set local role anon;
select pg_temp.ok('take 1 within the limit', pg_temp.err($q$select public.post_take('player-t9-0005', 'test-t', 'X', 'ok reason')$q$) = 'ok');
select pg_temp.ok('take 2 within the limit', pg_temp.err($q$select public.post_take('player-t9-0006', 'test-t', 'X', 'ok reason')$q$) = 'ok');
select pg_temp.ok('take 3 -> rate_limited', pg_temp.err($q$select public.post_take('player-t9-0007', 'test-t', 'X', 'ok reason')$q$) = 'rate_limited');
select pg_temp.ok('track accepts the new events',
  pg_temp.err($q$select public.track('[{"event_id":"3f9c2a1e-0000-4000-8000-000000000001","player":"player-t9-0005","event":"give_up"},{"event_id":"3f9c2a1e-0000-4000-8000-000000000002","player":"player-t9-0005","event":"hint"},{"event_id":"3f9c2a1e-0000-4000-8000-000000000003","player":"player-t9-0005","event":"take_post"}]')$q$) = 'ok');
reset role;

select test, ok, detail from _r order by at;
rollback;
