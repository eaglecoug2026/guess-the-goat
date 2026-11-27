-- SQL tests for 0010_take_pages.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
-- Reads every page the way the client does and returns the ids in order, plus the page count.
create function pg_temp.walk(p_player text, p_limit integer) returns jsonb language plpgsql as $$
declare
  v_page jsonb; v_last jsonb; v_ids jsonb := '[]'; v_pages integer := 0;
begin
  loop
    v_page := public.take_page('test-p', p_player, p_limit,
                               (v_last ->> 'seed')::boolean, (v_last ->> 'at')::timestamptz, (v_last ->> 'id')::bigint);
    v_pages := v_pages + 1;
    select v_ids || coalesce(jsonb_agg(t -> 'id'), '[]') into v_ids from jsonb_array_elements(v_page -> 'takes') t;
    v_last := v_page -> 'takes' -> -1;
    exit when not (v_page ->> 'more')::boolean or v_pages > 50;
  end loop;
  return jsonb_build_object('ids', v_ids, 'pages', v_pages);
end $$;

insert into public.catalog (slug, name, title, kind, opts, source, grp, sub) values
 ('test-p', 'Test P', 'GOAT test P', 'daily', '[{"name":"A","est":0.5},{"name":"B","est":0.3},{"name":"C","est":0.2},{"name":"D","est":0}]', 'builtin', 'Testing', 'P');
insert into public.takes (slug, author, pick, reason, seed, created_at) values
 ('test-p', 'Starter 1', 'A', 'Seeded one.', true, '2026-01-01'),
 ('test-p', 'Starter 2', 'B', 'Seeded two.', true, '2026-01-02');
-- 11 visible player takes, one a minute apart, and one hidden.
insert into public.takes (slug, player, pick, reason, created_at)
  select 'test-p', 'player-p-' || lpad(i::text, 4, '0'), 'A', 'Reason ' || i, timestamptz '2026-11-01 12:00' + i * interval '1 minute'
    from generate_series(1, 11) i;
insert into public.takes (slug, player, pick, reason, hidden, created_at)
  values ('test-p', 'player-p-hide', 'B', 'Hidden one.', true, '2026-11-01 13:00');
insert into public.takes (slug, player, pick, reason, created_at)
  values ('test-p', 'player-p-mine', 'C', 'My own take.', '2026-11-01 12:30');

set local role anon;
select pg_temp.ok('first page: 5 takes, more, total excludes hidden',
  (select jsonb_array_length(p -> 'takes') = 5 and (p ->> 'more')::boolean and (p ->> 'total')::int = 14 and p -> 'mine' = 'null'::jsonb
     from (select public.take_page('test-p') p) x));
select pg_temp.ok('first page is newest player takes first',
  (select array_agg(t ->> 'reason' order by o) = array['Reason 11','Reason 10','Reason 9','Reason 8','Reason 7']
     from (select public.take_page('test-p', 'player-p-mine') p) x, jsonb_array_elements(p -> 'takes') with ordinality e(t, o)));
select pg_temp.ok('own take comes back as mine, not in the page',
  (select p -> 'mine' ->> 'reason' = 'My own take.' and (p -> 'mine' ->> 'mine')::boolean
      and not exists (select 1 from jsonb_array_elements(p -> 'takes') t where (t ->> 'mine')::boolean)
     from (select public.take_page('test-p', 'player-p-mine') p) x));
reset role;  -- the next check reads the takes table itself to judge the walk
select pg_temp.ok('walking every page: each take once, starters last, no hidden, no own take',
  (select jsonb_array_length(w -> 'ids') = 13 and (w ->> 'pages')::int = 3
      and (select count(distinct v) from jsonb_array_elements(w -> 'ids') v) = 13
      and (w -> 'ids' -> 11)::bigint in (select id from public.takes where slug = 'test-p' and seed)
      and (w -> 'ids' -> 12)::bigint in (select id from public.takes where slug = 'test-p' and seed)
      and not exists (select 1 from public.takes t, jsonb_array_elements(w -> 'ids') v where t.id = (v #>> '{}')::bigint and (t.hidden or t.player = 'player-p-mine'))
     from (select pg_temp.walk('player-p-mine', 5) w) x));
set local role anon;
select pg_temp.ok('page size 1 walks all 14 for a player with no take',
  (select jsonb_array_length(w -> 'ids') = 14 and (w ->> 'pages')::int = 14 from (select pg_temp.walk('player-p-none', 1) w) x));
select pg_temp.ok('page size is capped at 20 and at least 1',
  (select jsonb_array_length(public.take_page('test-p', null, 500) -> 'takes') = 14
      and not (public.take_page('test-p', null, 500) ->> 'more')::boolean
      and jsonb_array_length(public.take_page('test-p', null, 0) -> 'takes') = 1));
select pg_temp.ok('mine is only on the first page',
  (select public.take_page('test-p', 'player-p-mine', 5, false, (p -> 'takes' -> -1 ->> 'at')::timestamptz, (p -> 'takes' -> -1 ->> 'id')::bigint) -> 'mine' = 'null'::jsonb
     from (select public.take_page('test-p', 'player-p-mine') p) x));
reset role;
-- A new take arriving between pages must not shift the next page. (Page 1 here is player-p-mine's 12:30 take, then 11 to 8.)
create temp table _p1 on commit drop as select public.take_page('test-p', null, 5) p;
grant select on _p1 to anon;
insert into public.takes (slug, player, pick, reason, created_at) values ('test-p', 'player-p-late', 'D', 'Arrived late.', now());
set local role anon;
select pg_temp.ok('a new take between pages does not repeat or skip anything',
  (select array_agg(t ->> 'reason' order by o) = array['Reason 7','Reason 6','Reason 5','Reason 4','Reason 3']
     from _p1, jsonb_array_elements(public.take_page('test-p', null, 5, (p -> 'takes' -> -1 ->> 'seed')::boolean,
                                                    (p -> 'takes' -> -1 ->> 'at')::timestamptz, (p -> 'takes' -> -1 ->> 'id')::bigint) -> 'takes')
          with ordinality e(t, o)));
reset role;
update public.takes set hidden = true where player = 'player-p-mine';
set local role anon;
select pg_temp.ok('own hidden take still comes back as mine, marked hidden',
  (select (p -> 'mine' ->> 'hidden')::boolean and (p ->> 'total')::int = 14 from (select public.take_page('test-p', 'player-p-mine') p) x));
select pg_temp.ok('unknown category -> empty page', (select p -> 'takes' = '[]'::jsonb and (p ->> 'total')::int = 0 and not (p ->> 'more')::boolean from (select public.take_page('no-such-cat') p) x));
reset role;

select test, ok, detail from _r order by at;
rollback;
