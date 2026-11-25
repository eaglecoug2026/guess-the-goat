-- SQL tests for 0004_owner_sessions.sql. One transaction, rolled back.
-- The real owner passphrase is never used or printed: after checking that the moved hash exists and is a
-- bcrypt hash, the test swaps in the hash of a throwaway test passphrase, inside this transaction only.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
create temp table _tok (name text primary key, token text) on commit drop;
grant all on _r, _tok to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.tok(p_name text) returns text language sql as $$ select token from _tok where name = p_name $$;

-- ---------- migration effects
select pg_temp.ok('owner_secret table dropped', to_regclass('public.owner_secret') is null);
select pg_temp.ok('check_owner / review_suggestion / remove_category dropped',
  to_regprocedure('public.check_owner(text)') is null
  and to_regprocedure('public.review_suggestion(text,uuid,text,text[])') is null
  and to_regprocedure('public.remove_category(text,uuid)') is null);
select pg_temp.ok('existing hash moved to secrets.owner_pass_hash (bcrypt, not printed)',
  exists (select 1 from public.secrets where key = 'owner_pass_hash' and value ~ '^\$2[aby]\$\d{2}\$'));

-- ---------- fixtures
update public.secrets set value = extensions.crypt('goat-test-pass-1', extensions.gen_salt('bf', 4)) where key = 'owner_pass_hash';
update public.catalog set active = false where active;
insert into public.catalog (slug, name, title, kind, opts, clues, source, needs_clues) values
 ('test-a', 'Test A', 'GOAT test A', 'daily',
  (select jsonb_agg(jsonb_build_object('name', 'A' || g, 'est', case when g <= 10 then (11 - g) / 100.0 else 0 end) order by g) from generate_series(1, 16) g),
  '{"A1":["1","2","3","4"],"A2":["1","2","3","4"],"A3":["1","2","3","4"]}', 'builtin', false),
 ('test-c', 'Test C', 'GOAT test C', 'daily',
  (select jsonb_agg(jsonb_build_object('name', 'C' || g, 'est', case when g <= 10 then (11 - g) / 100.0 else 0 end) order by g) from generate_series(1, 16) g),
  '{"C2":["1","2","3","4"]}', 'builtin', true);
insert into public.suggestions (id, name, opts, voter) values
 ('00000000-0000-4000-8000-000000000001', 'Test pizza place', '{One,Two,Three,Four,Five}', 'player-sugg-0001'),
 ('00000000-0000-4000-8000-000000000002', 'Test burger', '{One,Two}', 'player-sugg-0002'),
 ('00000000-0000-4000-8000-000000000003', 'Test taco', '{}', 'player-sugg-0003');

-- ---------- login
select set_config('request.headers', '{"x-forwarded-for":"192.0.2.50"}', true);
set local role anon;
select pg_temp.ok('wrong passphrase returns null', public.owner_login('not-the-pass') is null);
insert into _tok select 'main', public.owner_login('goat-test-pass-1');
insert into _tok select 'second', public.owner_login('goat-test-pass-1');
select pg_temp.ok('login returns a 32-byte base64url token', pg_temp.tok('main') ~ '^[A-Za-z0-9_-]{43}$');
select pg_temp.ok('anon cannot read owner_sessions', pg_temp.err('select * from public.owner_sessions') like 'permission denied%');
select pg_temp.ok('anon cannot read secrets', pg_temp.err('select * from public.secrets') like 'permission denied%');
select pg_temp.ok('anon cannot call require_owner', pg_temp.err($q$select public.require_owner('x')$q$) like 'permission denied%');
select pg_temp.ok('anon cannot call token_hash', pg_temp.err($q$select public.token_hash('x')$q$) like 'permission denied%');
reset role;
select pg_temp.ok('database stores only sha256(token), never the token',
  exists (select 1 from public.owner_sessions where token_hash = encode(sha256(convert_to(pg_temp.tok('main'), 'UTF8')), 'hex'))
  and not exists (select 1 from public.owner_sessions where token_hash = pg_temp.tok('main')));
select pg_temp.ok('session expires in 12 hours',
  (select expires_at - created_at from public.owner_sessions
    where token_hash = encode(sha256(convert_to(pg_temp.tok('main'), 'UTF8')), 'hex')) = interval '12 hours');
select pg_temp.ok('failed login logged (IP hash only)', exists (select 1 from public.ops_log where kind = 'owner_login_failed' and detail ->> 'ip_hash' ~ '^[0-9a-f]{64}$'));

-- ---------- owner functions require a valid token
insert into public.owner_sessions (token_hash, created_at, expires_at)
  values (encode(sha256(convert_to('expired-token-for-test', 'UTF8')), 'hex'), now() - interval '13 hours', now() - interval '1 hour');
set local role anon;
do $$
declare
  t text;
  calls text[] := array[
    'select public.owner_needs_clues(%L)',
    'select public.owner_schedule(%L)',
    'select public.owner_review_suggestion(%L, ''00000000-0000-4000-8000-000000000001'', ''dismiss'', null)',
    'select public.owner_remove_category(%L, ''test-a'')',
    'select public.owner_set_schedule(%L, current_date + 10, ''test-a'', null)',
    'select public.owner_set_correction(%L, current_date, ''x'')',
    'select public.owner_revoke_all(%L)'];
  c text;
  bad text := '';
begin
  foreach t in array array[null, 'garbage-token', 'expired-token-for-test'] loop
    foreach c in array calls loop
      if pg_temp.err(format(c, t)) <> 'not_owner' then
        bad := bad || format('[%s with %s] ', split_part(c, '(', 1), coalesce(t, 'null'));
      end if;
    end loop;
  end loop;
  perform pg_temp.ok('every owner function rejects missing, invalid and expired tokens', bad = '', nullif(bad, ''));
end $$;

-- needs-clues list
select pg_temp.ok('owner_needs_clues lists test-c with its current #1',
  (select count(*) from jsonb_array_elements(public.owner_needs_clues(pg_temp.tok('main'))) e
    where e ->> 'slug' = 'test-c' and e ->> 'top' = 'C1') = 1);

-- review: add / dismiss
select pg_temp.ok('add with 3 contenders -> bad_input',
  pg_temp.err(format($q$select public.owner_review_suggestion(%L, '00000000-0000-4000-8000-000000000002', 'add', '{One,Two,Three}')$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('add with a 41-char contender -> bad_input',
  pg_temp.err(format($q$select public.owner_review_suggestion(%L, '00000000-0000-4000-8000-000000000002', 'add', array['One','Two','Three',repeat('x',41)])$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('add with 4 edited contenders -> community slug',
  public.owner_review_suggestion(pg_temp.tok('main'), '00000000-0000-4000-8000-000000000001', 'add', '{One, Two ,three,THREE,Four}')
  = 'community-00000000');
select pg_temp.ok('dismiss works', pg_temp.err(format($q$select public.owner_review_suggestion(%L, '00000000-0000-4000-8000-000000000003', 'dismiss', null)$q$, pg_temp.tok('main'))) = 'ok');
select pg_temp.ok('reviewing a non-pending suggestion -> bad_input',
  pg_temp.err(format($q$select public.owner_review_suggestion(%L, '00000000-0000-4000-8000-000000000003', 'dismiss', null)$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('unknown action -> bad_input',
  pg_temp.err(format($q$select public.owner_review_suggestion(%L, '00000000-0000-4000-8000-000000000002', 'publish', null)$q$, pg_temp.tok('main'))) = 'bad_input');
reset role;
select pg_temp.ok('added category: vote kind, community source, deduped contenders with est 0, suggestion added',
  (select kind = 'vote' and source = 'community' and title = 'GOAT test pizza place'
          and opts = '[{"name":"One","est":0},{"name":"Two","est":0},{"name":"three","est":0},{"name":"Four","est":0}]'::jsonb
     from public.catalog where slug = 'community-00000000')
  and (select status from public.suggestions where id = '00000000-0000-4000-8000-000000000001') = 'added'
  and (select status from public.suggestions where id = '00000000-0000-4000-8000-000000000003') = 'dismissed');

-- remove = deactivate, never delete
set local role anon;
select pg_temp.ok('remove category ok', pg_temp.err(format($q$select public.owner_remove_category(%L, 'community-00000000')$q$, pg_temp.tok('main'))) = 'ok');
select pg_temp.ok('removed category hidden from the public', (select count(*) from public.catalog where slug = 'community-00000000') = 0);
select pg_temp.ok('removing it again -> bad_input', pg_temp.err(format($q$select public.owner_remove_category(%L, 'community-00000000')$q$, pg_temp.tok('main'))) = 'bad_input');
reset role;
select pg_temp.ok('removed category still exists (active = false), its suggestion dismissed',
  (select not active from public.catalog where slug = 'community-00000000')
  and (select status from public.suggestions where id = '00000000-0000-4000-8000-000000000001') = 'dismissed');

-- schedule overrides
insert into public.daily_puzzles (puzzle_date, puzzle_no, slug, name, title, ranking, answer, clues, k, total_votes, tier)
  values (public.utc_today() + 5, 900000, 'test-a', 'Test A', 'GOAT test A', '[]', 'A1', '["1","2","3","4"]', 100, 0, 'estimated')
  on conflict do nothing;
set local role anon;
select pg_temp.ok('set override for today + 10', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date + 10, 'test-a', 'test note')$q$, pg_temp.tok('main'))) = 'ok');
select pg_temp.ok('owner_schedule lists 30 dates including the override',
  (select jsonb_array_length(s) = 30
          and exists (select 1 from jsonb_array_elements(s) e where e ->> 'slug' = 'test-a' and e ->> 'note' = 'test note')
     from (select public.owner_schedule(pg_temp.tok('main')) s) x));
select pg_temp.ok('override on a frozen date -> bad_input', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date + 5, 'test-a', null)$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('override 30 days out -> bad_input', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date + 30, 'test-a', null)$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('override in the past -> bad_input', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date - 1, 'test-a', null)$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('override with an inactive category -> bad_input', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date + 11, 'community-00000000', null)$q$, pg_temp.tok('main'))) = 'bad_input');
select pg_temp.ok('clear override with null slug', pg_temp.err(format($q$select public.owner_set_schedule(%L, (now() at time zone 'utc')::date + 10, null, null)$q$, pg_temp.tok('main'))) = 'ok');
reset role;
select pg_temp.ok('override cleared', not exists (select 1 from public.schedule where puzzle_date = public.utc_today() + 10));

-- correction note (the only change allowed on a published puzzle)
set local role anon;
select pg_temp.ok('owner sets a correction note', pg_temp.err(format($q$select public.owner_set_correction(%L, (now() at time zone 'utc')::date + 5, 'Clue 2 corrected')$q$, pg_temp.tok('main'))) = 'ok');
select pg_temp.ok('correction on a date with no puzzle -> bad_input', pg_temp.err(format($q$select public.owner_set_correction(%L, '1999-01-01', 'x')$q$, pg_temp.tok('main'))) = 'bad_input');
reset role;
select pg_temp.ok('correction_note stored', (select correction_note from public.daily_puzzles where puzzle_date = public.utc_today() + 5) = 'Clue 2 corrected');

-- logout / revoke all
set local role anon;
select pg_temp.ok('logout ok', pg_temp.err(format($q$select public.owner_logout(%L)$q$, pg_temp.tok('second'))) = 'ok');
select pg_temp.ok('revoked token rejected', pg_temp.err(format($q$select public.owner_needs_clues(%L)$q$, pg_temp.tok('second'))) = 'not_owner');
select pg_temp.ok('main token still valid', pg_temp.err(format($q$select public.owner_needs_clues(%L)$q$, pg_temp.tok('main'))) = 'ok');
insert into _tok select 'third', public.owner_login('goat-test-pass-1');
select pg_temp.ok('revoke all ok', pg_temp.err(format($q$select public.owner_revoke_all(%L)$q$, pg_temp.tok('main'))) = 'ok');
select pg_temp.ok('after revoke all, every token is rejected',
  pg_temp.err(format($q$select public.owner_needs_clues(%L)$q$, pg_temp.tok('main'))) = 'not_owner'
  and pg_temp.err(format($q$select public.owner_needs_clues(%L)$q$, pg_temp.tok('third'))) = 'not_owner');
reset role;
select pg_temp.ok('no unrevoked sessions remain', not exists (select 1 from public.owner_sessions where revoked_at is null));

-- ---------- login rate limit: 5 per 15 minutes per IP hash (failed attempts count)
select set_config('request.headers', '{"x-forwarded-for":"192.0.2.60"}', true);
set local role anon;
do $$
declare i integer; bad integer := 0;
begin
  for i in 1..5 loop
    if pg_temp.err($q$select public.owner_login('wrong-pass')$q$) <> 'ok' then bad := bad + 1; end if;
  end loop;
  perform pg_temp.ok('5 attempts in 15 minutes allowed', bad = 0);
  perform pg_temp.ok('6th login from the same IP hash -> rate_limited (even with the right passphrase)',
    pg_temp.err($q$select public.owner_login('goat-test-pass-1')$q$) = 'rate_limited');
end $$;
reset role;
select set_config('request.headers', '{"x-forwarded-for":"192.0.2.61"}', true);
set local role anon;
select pg_temp.ok('another IP can still log in', public.owner_login('goat-test-pass-1') ~ '^[A-Za-z0-9_-]{43}$');
reset role;

select test, ok, detail from _r order by at;
rollback;
