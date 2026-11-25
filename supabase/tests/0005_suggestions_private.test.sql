-- SQL tests for 0005_suggestions_private.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
create temp table _tok (name text primary key, token text) on commit drop;
grant all on _r, _tok to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.tok(p_name text) returns text language sql as $$ select token from _tok where name = p_name $$;

update public.secrets set value = extensions.crypt('goat-test-pass-1', extensions.gen_salt('bf', 4)) where key = 'owner_pass_hash';
update public.catalog set active = false where active;
insert into public.catalog (slug, name, title, kind, opts, source) values
 ('test-a', 'Test A', 'GOAT test A', 'vote', '[{"name":"W","est":0},{"name":"X","est":0},{"name":"Y","est":0},{"name":"Z","est":0}]', 'builtin');

select pg_temp.ok('suggest now takes p_player', pg_get_function_arguments('public.suggest(text,text,text[])'::regprocedure) like 'p_player text%');

-- ---------- privacy
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.80"}', true);
set local role anon;
select pg_temp.ok('anon cannot select suggestions', pg_temp.err('select * from public.suggestions') like 'permission denied%');
select pg_temp.ok('anon cannot select suggestions (name column)', pg_temp.err('select name from public.suggestions') like 'permission denied%');
select pg_temp.ok('suggest returns an id', pg_temp.err($q$select public.suggest('player-s5-0001', '  Test   pizza place ', '{Foo, foo ,Bar}')$q$) = 'ok');
select pg_temp.ok('another player''s suggestion', pg_temp.err($q$select public.suggest('player-s5-0002', 'Test burger', '{}')$q$) = 'ok');
select pg_temp.ok('my_suggestions returns only that player''s rows, pending',
  (select jsonb_array_length(m) = 1 and m -> 0 ->> 'name' = 'Test pizza place' and m -> 0 ->> 'status' = 'pending'
     from (select public.my_suggestions('player-s5-0001') m) x));
select pg_temp.ok('my_suggestions for an unknown player is empty', public.my_suggestions('player-nobody-01') = '[]'::jsonb);
select pg_temp.ok('my_suggestions with a short id -> bad_input', pg_temp.err($q$select public.my_suggestions('short')$q$) = 'bad_input');
reset role;
select pg_temp.ok('stored: whitespace collapsed, contenders deduped ignoring case, IP hashed',
  (select name = 'Test pizza place' and opts = '{Foo,Bar}' and ip_hash ~ '^[0-9a-f]{64}$'
     from public.suggestions where voter = 'player-s5-0001'));

-- ---------- validation
set local role anon;
select pg_temp.ok('duplicate pending name (any case) -> duplicate', pg_temp.err($q$select public.suggest('player-s5-0003', 'TEST PIZZA PLACE', '{}')$q$) = 'duplicate');
select pg_temp.ok('name already in the catalog -> duplicate', pg_temp.err($q$select public.suggest('player-s5-0003', 'test a', '{}')$q$) = 'duplicate');
select pg_temp.ok('1-char name -> bad_input', pg_temp.err($q$select public.suggest('player-s5-0003', 'x', '{}')$q$) = 'bad_input');
select pg_temp.ok('61-char name -> bad_input', pg_temp.err(format($q$select public.suggest('player-s5-0003', %L, '{}')$q$, repeat('n', 61))) = 'bad_input');
select pg_temp.ok('41-char contender -> bad_input', pg_temp.err(format($q$select public.suggest('player-s5-0003', 'Test fries', array[%L])$q$, repeat('c', 41))) = 'bad_input');
select pg_temp.ok('17 contenders -> bad_input', pg_temp.err($q$select public.suggest('player-s5-0003', 'Test fries', (select array_agg('c' || g) from generate_series(1, 17) g))$q$) = 'bad_input');
select pg_temp.ok('16 contenders ok', pg_temp.err($q$select public.suggest('player-s5-0003', 'Test fries', (select array_agg('c' || g) from generate_series(1, 16) g))$q$) = 'ok');
select pg_temp.ok('short player id -> bad_input', pg_temp.err($q$select public.suggest('short', 'Test shakes', '{}')$q$) = 'bad_input');
reset role;

-- ---------- limits: 10 per day per player, 10 per day per IP hash
set local role anon;
do $$
declare i integer; bad integer := 0;
begin
  for i in 1..10 loop
    perform set_config('request.headers', format('{"x-forwarded-for":"198.18.0.%s"}', i), true);
    if pg_temp.err(format($q$select public.suggest('player-s5-limit', 'Per player test %s', '{}')$q$, i)) <> 'ok' then bad := bad + 1; end if;
  end loop;
  perform pg_temp.ok('10 suggestions from one player (different IPs) succeed', bad = 0, format('%s failed', bad));
  perform set_config('request.headers', '{"x-forwarded-for":"198.18.0.99"}', true);
  perform pg_temp.ok('11th from the same player -> rate_limited',
    pg_temp.err($q$select public.suggest('player-s5-limit', 'Per player test 11', '{}')$q$) = 'rate_limited');
  bad := 0;
  perform set_config('request.headers', '{"x-forwarded-for":"198.18.1.1"}', true);
  for i in 1..10 loop
    if pg_temp.err(format($q$select public.suggest('player-s5-ip-%s', 'Per IP test %s', '{}')$q$, lpad(i::text, 3, '0'), i)) <> 'ok' then bad := bad + 1; end if;
  end loop;
  perform pg_temp.ok('10 suggestions from one IP (different players) succeed', bad = 0, format('%s failed', bad));
  perform pg_temp.ok('11th from the same IP hash -> rate_limited',
    pg_temp.err($q$select public.suggest('player-s5-ip-011', 'Per IP test 11', '{}')$q$) = 'rate_limited');
end $$;
reset role;

-- ---------- owner queue + review timestamps
select set_config('request.headers', '{"x-forwarded-for":"192.0.2.70"}', true);
set local role anon;
insert into _tok select 'main', public.owner_login('goat-test-pass-1');
select pg_temp.ok('owner_queue without a token -> not_owner', pg_temp.err('select public.owner_queue(null)') = 'not_owner');
select pg_temp.ok('owner_queue lists pending suggestions',
  (select count(*) from jsonb_array_elements(public.owner_queue(pg_temp.tok('main'))) e where e ->> 'name' = 'Test pizza place') = 1);
reset role;
do $$
declare v_id uuid := (select id from public.suggestions where voter = 'player-s5-0001');
        v_id2 uuid := (select id from public.suggestions where voter = 'player-s5-0002');
begin
  execute 'set local role anon';
  perform public.owner_review_suggestion(pg_temp.tok('main'), v_id, 'add', '{One,Two,Three,Four}');
  perform public.owner_review_suggestion(pg_temp.tok('main'), v_id2, 'dismiss', null);
  perform pg_temp.ok('player sees the added status', public.my_suggestions('player-s5-0001') -> 0 ->> 'status' = 'added');
  perform pg_temp.ok('reviewed suggestions leave the queue',
    (select count(*) from jsonb_array_elements(public.owner_queue(pg_temp.tok('main'))) e where (e ->> 'id')::uuid in (v_id, v_id2)) = 0);
  execute 'reset role';
  perform pg_temp.ok('reviewed_at set on add and dismiss',
    (select count(*) from public.suggestions where id in (v_id, v_id2) and reviewed_at is not null) = 2);
end $$;

-- ---------- kill switch
update public.config set value = 'false' where key = 'suggestions_enabled';
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.81"}', true);
set local role anon;
select pg_temp.ok('suggestions_enabled=false -> disabled', pg_temp.err($q$select public.suggest('player-s5-0009', 'Test donuts', '{}')$q$) = 'disabled');
reset role;

select test, ok, detail from _r order by at;
rollback;
