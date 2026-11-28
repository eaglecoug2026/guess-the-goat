-- SQL tests for 0013_take_replies.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
create temp table _tok (name text primary key, token text) on commit drop;
create temp table _ids (name text primary key, id bigint) on commit drop;
grant all on _r, _tok, _ids to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.id(p_name text) returns bigint language sql as $$ select id from _ids where name = p_name $$;

update public.secrets set value = extensions.crypt('goat-test-pass-1', extensions.gen_salt('bf', 4)) where key = 'owner_pass_hash';
insert into public.secrets (key, value) values ('blocked_words', 'zzbadword,qqrude') on conflict (key) do update set value = excluded.value;
insert into public.catalog (slug, name, title, kind, opts, source, grp, sub) values
 ('test-r', 'Test R', 'GOAT test R', 'daily', '[{"name":"Ann Alpha","est":0.5},{"name":"Bo Beta","est":0.3},{"name":"Cy Gamma","est":0.2},{"name":"Di Delta","est":0}]', 'builtin', 'Testing', 'R');
insert into public.takes (slug, author, pick, reason, seed) values ('test-r', 'Starter Sam', 'Bo Beta', 'Seeded reason here.', true);
insert into _ids select 'seed', id from public.takes where slug = 'test-r' and seed;
insert into public.takes (slug, player, author, pick, reason, hidden) values ('test-r', 'player-r-hidden', 'Hid', 'Cy Gamma', 'A hidden take.', true);
insert into _ids select 'hidden', id from public.takes where slug = 'test-r' and player = 'player-r-hidden';

-- ---------- takes: edited flag
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.130"}', true);
set local role anon;
select pg_temp.ok('a new take is not edited and has 0 replies',
  (select not (p -> 'take' ->> 'edited')::boolean and (p -> 'take' ->> 'replies')::int = 0
     from (select public.post_take('player-r-0001', 'test-r', 'Ann Alpha', 'First version.', 'Pat') p) x));
select pg_temp.ok('posting the same text again is not an edit',
  (select not (p -> 'take' ->> 'edited')::boolean from (select public.post_take('player-r-0001', 'test-r', 'ann alpha', 'First   version.', 'Pat') p) x));
select pg_temp.ok('changing the text marks it edited',
  (select (p -> 'take' ->> 'edited')::boolean and p -> 'take' ->> 'reason' = 'Second version.'
     from (select public.post_take('player-r-0001', 'test-r', 'Ann Alpha', 'Second version.', 'Pat') p) x));
reset role;
insert into _ids select 'take1', id from public.takes where player = 'player-r-0001';

-- ---------- replies: posting
set local role anon;
select pg_temp.ok('anon cannot select replies', pg_temp.err('select * from public.take_replies') like 'permission denied%');
select pg_temp.ok('reply to a take',
  (select p ->> 'body' = 'I disagree, here is why.' and p ->> 'author' = 'Lee' and (p ->> 'mine')::boolean
          and not (p ->> 'edited')::boolean and (p ->> 'take')::bigint = pg_temp.id('take1') and not (p::text like '%player-r%')
     from (select public.post_reply('player-r-0002', pg_temp.id('take1'), '  I   disagree, here is why. ', 'Lee') p) x));
select pg_temp.ok('reply to a starter take', pg_temp.err(format($q$select public.post_reply('player-r-0003', %s, 'Starter takes are fair game.')$q$, pg_temp.id('seed'))) = 'ok');
select pg_temp.ok('the author can reply to their own take', pg_temp.err(format($q$select public.post_reply('player-r-0001', %s, 'Replying to myself.')$q$, pg_temp.id('take1'))) = 'ok');
select pg_temp.ok('a player can reply more than once', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'One more thing.')$q$, pg_temp.id('take1'))) = 'ok');
select pg_temp.ok('reply to a hidden take -> not_found', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'Hello there.')$q$, pg_temp.id('hidden'))) = 'not_found');
select pg_temp.ok('reply to a missing take -> not_found', pg_temp.err($q$select public.post_reply('player-r-0002', 999999999, 'Hello there.')$q$) = 'not_found');
select pg_temp.ok('link in a reply -> blocked', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'see www.example.com')$q$, pg_temp.id('take1'))) = 'blocked');
select pg_temp.ok('blocked word in a reply -> blocked', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'what a ZZBADWORD')$q$, pg_temp.id('take1'))) = 'blocked');
select pg_temp.ok('blocked word in the name -> blocked', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'fine reply', 'qqrude')$q$, pg_temp.id('take1'))) = 'blocked');
select pg_temp.ok('1-char reply -> bad_input', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, ' x ')$q$, pg_temp.id('take1'))) = 'bad_input');
select pg_temp.ok('281-char reply -> bad_input', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, %L)$q$, pg_temp.id('take1'), repeat('a', 281))) = 'bad_input');
select pg_temp.ok('25-char name -> bad_input', pg_temp.err(format($q$select public.post_reply('player-r-0002', %s, 'fine reply', %L)$q$, pg_temp.id('take1'), repeat('a', 25))) = 'bad_input');
select pg_temp.ok('short player id -> bad_input', pg_temp.err(format($q$select public.post_reply('short', %s, 'fine reply')$q$, pg_temp.id('take1'))) = 'bad_input');
select pg_temp.ok('take_json counts replies',
  (select (t ->> 'replies')::int = 3 from jsonb_array_elements(public.take_page('test-r', 'player-r-0009') -> 'takes') t where (t ->> 'id')::bigint = pg_temp.id('take1')));
reset role;

-- ---------- replies: reading
insert into _ids select 'r1', min(id) from public.take_replies where take_id = pg_temp.id('take1');
-- Spread the times so the order is certain.
update public.take_replies set created_at = now() - interval '10 minutes' + (id - pg_temp.id('r1')) * interval '1 minute' where take_id = pg_temp.id('take1');
insert into public.take_replies (take_id, player, body, created_at)
  select pg_temp.id('take1'), 'player-r-' || lpad(i::text, 4, '0'), 'Bulk reply ' || i, now() - interval '5 minutes' + i * interval '1 second'
    from generate_series(10, 16) i;
set local role anon;
select pg_temp.ok('reply_page: 5 oldest first, more, total',
  (select jsonb_array_length(p -> 'replies') = 5 and (p ->> 'more')::boolean and (p ->> 'total')::int = 10
          and p -> 'replies' -> 0 ->> 'body' = 'I disagree, here is why.'
     from (select public.reply_page(pg_temp.id('take1'), 'player-r-0002') p) x));
select pg_temp.ok('mine only on the asking player''s replies',
  (select count(*) filter (where (r ->> 'mine')::boolean) = 2 from jsonb_array_elements(public.reply_page(pg_temp.id('take1'), 'player-r-0002', 20) -> 'replies') r));
select pg_temp.ok('the next page starts after the last one shown, nothing repeats',
  (select jsonb_array_length(n -> 'replies') = 5 and not (n ->> 'more')::boolean
          and not exists (select 1 from jsonb_array_elements(p -> 'replies') a, jsonb_array_elements(n -> 'replies') b where a -> 'id' = b -> 'id')
     from (select p, public.reply_page(pg_temp.id('take1'), null, 5, (p -> 'replies' -> -1 ->> 'at')::timestamptz, (p -> 'replies' -> -1 ->> 'id')::bigint) n
             from (select public.reply_page(pg_temp.id('take1')) p) y) x));
select pg_temp.ok('page size capped at 20', (select jsonb_array_length(public.reply_page(pg_temp.id('take1'), null, 500) -> 'replies') = 10));
select pg_temp.ok('a hidden take shows no replies', (select (p ->> 'total')::int = 0 and p -> 'replies' = '[]'::jsonb from (select public.reply_page(pg_temp.id('hidden')) p) x));

-- ---------- replies: editing
select pg_temp.ok('edit own reply -> new text, edited',
  (select p ->> 'body' = 'I disagree, edited.' and (p ->> 'edited')::boolean
     from (select public.edit_reply('player-r-0002', pg_temp.id('r1'), 'I disagree,   edited.') p) x));
select pg_temp.ok('someone else''s reply -> not_found', pg_temp.err(format($q$select public.edit_reply('player-r-0003', %s, 'Not mine to change.')$q$, pg_temp.id('r1'))) = 'not_found');
select pg_temp.ok('edit with a blocked word -> blocked', pg_temp.err(format($q$select public.edit_reply('player-r-0002', %s, 'zzbadword now')$q$, pg_temp.id('r1'))) = 'blocked');
select pg_temp.ok('edit too short -> bad_input', pg_temp.err(format($q$select public.edit_reply('player-r-0002', %s, 'a')$q$, pg_temp.id('r1'))) = 'bad_input');
select pg_temp.ok('the edit shows to everyone',
  (select p -> 'replies' -> 0 ->> 'body' = 'I disagree, edited.' and (p -> 'replies' -> 0 ->> 'edited')::boolean and not (p -> 'replies' -> 0 ->> 'mine')::boolean
     from (select public.reply_page(pg_temp.id('take1')) p) x));
reset role;

-- ---------- owner
insert into _tok values ('a', (select public.owner_login('goat-test-pass-1')));
set local role anon;
select pg_temp.ok('owner_replies needs a token', pg_temp.err($q$select public.owner_replies('bad-token')$q$) = 'not_owner');
select pg_temp.ok('owner_replies lists replies with their take',
  (select exists (select 1 from jsonb_array_elements(o) e where e ->> 'body' = 'I disagree, edited.' and e ->> 'slug' = 'test-r' and e ->> 'take_pick' = 'Ann Alpha')
     from (select public.owner_replies((select token from _tok where name = 'a')) o) x));
select pg_temp.ok('owner hides a reply', pg_temp.err(format($q$select public.owner_hide_reply(%L, %s, true)$q$, (select token from _tok where name = 'a'), pg_temp.id('r1'))) = 'ok');
select pg_temp.ok('hidden reply is gone for others, kept for its author, and not counted',
  (select (public.reply_page(pg_temp.id('take1')) ->> 'total')::int = 9
      and not exists (select 1 from jsonb_array_elements(public.reply_page(pg_temp.id('take1'), null, 20) -> 'replies') r where (r ->> 'id')::bigint = pg_temp.id('r1'))
      and exists (select 1 from jsonb_array_elements(public.reply_page(pg_temp.id('take1'), 'player-r-0002', 20) -> 'replies') r where (r ->> 'id')::bigint = pg_temp.id('r1') and (r ->> 'hidden')::boolean)
      and (select (t ->> 'replies')::int = 9 from jsonb_array_elements(public.take_page('test-r') -> 'takes') t where (t ->> 'id')::bigint = pg_temp.id('take1'))));
select pg_temp.ok('owner_hide_reply on a missing id -> bad_input', pg_temp.err(format($q$select public.owner_hide_reply(%L, 999999999, true)$q$, (select token from _tok where name = 'a'))) = 'bad_input');
select pg_temp.ok('owner_delete_player deletes replies',
  (select (d ->> 'replies')::int = 2 from (select public.owner_delete_player((select token from _tok where name = 'a'), 'player-r-0002') d) x));
reset role;
select pg_temp.ok('their replies are gone', not exists (select 1 from public.take_replies where player = 'player-r-0002'));
delete from public.takes where id = pg_temp.id('take1');
select pg_temp.ok('deleting a take deletes its replies', not exists (select 1 from public.take_replies where take_id = pg_temp.id('take1')));

-- ---------- switches and limits
update public.config set value = 'false' where key = 'takes_enabled';
set local role anon;
select pg_temp.ok('takes_enabled = false -> replies disabled', pg_temp.err(format($q$select public.post_reply('player-r-0004', %s, 'ok reply')$q$, pg_temp.id('seed'))) = 'disabled');
reset role;
update public.config set value = 'true' where key = 'takes_enabled';
update public.config set value = jsonb_set(value, '{reply,limit}', '2') where key = 'rate_limits';
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.131"}', true);
set local role anon;
select pg_temp.ok('reply 1 within the limit', pg_temp.err(format($q$select public.post_reply('player-r-0005', %s, 'ok reply')$q$, pg_temp.id('seed'))) = 'ok');
select pg_temp.ok('reply 2 within the limit', pg_temp.err(format($q$select public.post_reply('player-r-0006', %s, 'ok reply')$q$, pg_temp.id('seed'))) = 'ok');
select pg_temp.ok('reply 3 -> rate_limited', pg_temp.err(format($q$select public.post_reply('player-r-0007', %s, 'ok reply')$q$, pg_temp.id('seed'))) = 'rate_limited');
reset role;

select test, ok, detail from _r order by at;
rollback;
