-- SQL tests for 0003_daily.sql. One transaction, rolled back. Uses 2099 dates for the freeze logic so real
-- puzzles are never touched; the get_daily window checks use the real UTC date and are skipped if a real
-- puzzle already exists for it.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
-- 16 contenders P1..P16 with descending estimates; clues for the listed names.
create function pg_temp.opts(p text) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('name', p || g, 'est',
         (array[0.30,0.20,0.15,0.10,0.08,0.06,0.04,0.03,0.02,0.01,0,0,0,0,0,0])[g]) order by g)
    from generate_series(1, 16) g $$;
create function pg_temp.clues(variadic names text[]) returns jsonb language sql as $$
  select jsonb_object_agg(n, jsonb_build_array(n || ' c1', n || ' c2', n || ' c3', n || ' c4')) from unnest(names) n $$;
create function pg_temp.slug_on(d date) returns text language sql as $$ select slug from public.daily_puzzles where puzzle_date = d $$;

-- ---------- fixtures
update public.catalog set active = false where active;
insert into public.catalog (slug, name, title, kind, season, opts, clues, source) values
 ('test-a', 'Test A', 'GOAT test A', 'daily', null,       pg_temp.opts('A'), pg_temp.clues('A1','A2','A3'), 'builtin'),
 ('test-b', 'Test B', 'GOAT test B', 'daily', null,       pg_temp.opts('B'), pg_temp.clues('B1','B2','B3'), 'builtin'),
 ('test-c', 'Test C', 'GOAT test C', 'daily', null,       pg_temp.opts('C'), pg_temp.clues('C2','C3','C4'), 'builtin'),
 ('test-s', 'Test S', 'GOAT test S', 'daily', 'halloween', pg_temp.opts('S'), pg_temp.clues('S1','S2','S3'), 'builtin'),
 ('test-v', 'Test V', 'GOAT test V', 'vote',  null,       pg_temp.opts('V'), pg_temp.clues('V1','V2','V3'), 'community');

-- ---------- launch_date unset -> no-op
update public.config set value = 'null' where key = 'launch_date';
select pg_temp.ok('launch_date null: freeze_puzzle returns null', public.freeze_puzzle('2099-03-01') is null);
select pg_temp.ok('launch_date null: freeze_upcoming returns 0', public.freeze_upcoming('2099-03-01') = 0);

update public.config set value = '"2099-01-01"' where key = 'launch_date';
select pg_temp.ok('date before launch_date: null', public.freeze_puzzle('2098-12-31') is null);

-- ---------- first freeze
select pg_temp.ok('2099-03-01 freezes test-a (least recently used, ties by slug)', (public.freeze_puzzle('2099-03-01') ->> 'slug') = 'test-a');
select pg_temp.ok('puzzle_no = date - launch_date + 1', (select puzzle_no from public.daily_puzzles where puzzle_date = '2099-03-01') = 60);
select pg_temp.ok('snapshot: 16 ranked, answer A1, its 4 clues, estimated tier, k 100, 0 votes',
  (select jsonb_array_length(ranking) = 16 and answer = 'A1' and clues = pg_temp.clues('A1') -> 'A1'
          and tier = 'estimated' and k = 100 and total_votes = 0
          and ranking -> 0 ->> 'name' = 'A1' and (ranking -> 0 ->> 'rank')::int = 1
          and ranking -> 0 ? 'est' and ranking -> 0 ? 'votes' and ranking -> 0 ? 'blended'
     from public.daily_puzzles where puzzle_date = '2099-03-01'));
select pg_temp.ok('clue mismatch: test-c (#1 C1 has no clues) flagged needs_clues',
  (select needs_clues from public.catalog where slug = 'test-c')
  and not (select needs_clues from public.catalog where slug = 'test-a'));
select pg_temp.ok('frozen log written', exists (select 1 from public.ops_log where kind = 'frozen' and detail ->> 'date' = '2099-03-01'));

-- ---------- same date = same puzzle, even after votes move the ranking
do $$
declare first jsonb := public.freeze_puzzle('2099-03-01');
begin
  insert into public.catalog_votes (slug, player, pick)
    select 'test-a', 'tplayer-' || lpad(g::text, 6, '0'), 'A2' from generate_series(1, 500) g;
  perform pg_temp.ok('votes after freezing do not change the snapshot',
    public.freeze_puzzle('2099-03-01') = first and (first ->> 'answer') = 'A1');
  perform pg_temp.ok('live ranking moved (A2 now #1) while the snapshot stayed', public.ranking_of('test-a') -> 'ranking' -> 0 ->> 'name' = 'A2');
end $$;

-- ---------- repeat window, pool exhaustion
select pg_temp.ok('2099-03-02 -> test-b (test-a used in the last 30)', (public.freeze_puzzle('2099-03-02') ->> 'slug') = 'test-b');
select pg_temp.ok('2099-03-03 -> pool exhausted, least recently used test-a',
  (public.freeze_puzzle('2099-03-03') ->> 'slug') = 'test-a'
  and exists (select 1 from public.ops_log where kind = 'pool_exhausted' and detail ->> 'date' = '2099-03-03'));
select pg_temp.ok('snapshot uses the blended #1 at freeze time (A2, community tier, 500 votes, A2 clues)',
  (select answer = 'A2' and tier = 'community' and total_votes = 500 and clues = pg_temp.clues('A2') -> 'A2'
     from public.daily_puzzles where puzzle_date = '2099-03-03'));
select pg_temp.ok('seasonal and vote categories are never picked from the pool',
  not exists (select 1 from public.daily_puzzles where slug in ('test-s','test-v')));

-- ---------- schedule overrides
insert into public.schedule (puzzle_date, slug, note) values ('2099-03-04', 'test-s', 'halloween test'), ('2099-03-05', 'test-c', 'no clues');
select pg_temp.ok('schedule row wins (seasonal test-s on 2099-03-04)', (public.freeze_puzzle('2099-03-04') ->> 'slug') = 'test-s');
select pg_temp.ok('scheduled category whose #1 lacks clues is skipped and logged',
  (public.freeze_puzzle('2099-03-05') ->> 'slug') <> 'test-c'
  and exists (select 1 from public.ops_log where kind = 'schedule_skipped' and detail ->> 'slug' = 'test-c'
                and detail ->> 'reason' = 'needs_clues'));

-- ---------- clue mismatch from votes: test-b's blended #1 becomes B4 (no clues)
insert into public.catalog_votes (slug, player, pick)
  select 'test-b', 'bplayer-' || lpad(g::text, 6, '0'), 'B4' from generate_series(1, 300) g;
select pg_temp.ok('test-b skipped once its #1 (B4) has no clues',
  (public.freeze_puzzle('2099-03-06') ->> 'slug') <> 'test-b'
  and (select needs_clues from public.catalog where slug = 'test-b'));

-- ---------- immutability (as postgres, i.e. even with table privileges)
select pg_temp.ok('UPDATE of a published puzzle fails', pg_temp.err($q$update public.daily_puzzles set answer = 'X' where puzzle_date = '2099-03-01'$q$) = 'immutable');
select pg_temp.ok('UPDATE of ranking fails', pg_temp.err($q$update public.daily_puzzles set ranking = '[]' where puzzle_date = '2099-03-01'$q$) = 'immutable');
select pg_temp.ok('DELETE of a published puzzle fails', pg_temp.err($q$delete from public.daily_puzzles where puzzle_date = '2099-03-01'$q$) = 'immutable');
select pg_temp.ok('TRUNCATE fails', pg_temp.err('truncate public.daily_puzzles') = 'immutable');
select pg_temp.ok('correction_note may be set', pg_temp.err($q$update public.daily_puzzles set correction_note = 'Fixed a clue' where puzzle_date = '2099-03-01'$q$) = 'ok'
  and (select correction_note from public.daily_puzzles where puzzle_date = '2099-03-01') = 'Fixed a clue');

-- ---------- freeze horizon (>= 48 h) with a mocked UTC date
select pg_temp.ok('freeze_upcoming(2099-04-10) freezes 2099-04-09 .. 2099-04-13', public.freeze_upcoming('2099-04-10') = 5,
  (select string_agg(puzzle_date::text, ',' order by puzzle_date) from public.daily_puzzles where puzzle_date between '2099-04-09' and '2099-04-13'));
select pg_temp.ok('every date through UTC date + 3 exists',
  (select count(*) from generate_series('2099-04-10'::date, '2099-04-13'::date, '1 day') d
    where exists (select 1 from public.daily_puzzles p where p.puzzle_date = d::date)) = 4);
select pg_temp.ok('freeze_upcoming is idempotent', public.freeze_upcoming('2099-04-10') = 0);

-- ---------- nothing eligible
update public.catalog set active = false where slug like 'test-%';
select pg_temp.ok('no eligible category: null + freeze_failed logged',
  public.freeze_puzzle('2099-05-01') is null
  and exists (select 1 from public.ops_log where kind = 'freeze_failed' and detail ->> 'date' = '2099-05-01'));
update public.catalog set active = true where slug in ('test-a','test-s','test-v');

-- ---------- anon
set local role anon;
select pg_temp.ok('anon cannot see dates past UTC+1 (2099 rows hidden)', (select count(*) from public.daily_puzzles where puzzle_date >= '2099-01-01') = 0);
select pg_temp.ok('anon cannot update daily_puzzles', pg_temp.err($q$update public.daily_puzzles set correction_note = 'x' where true$q$) like 'permission denied%');
select pg_temp.ok('anon cannot delete daily_puzzles', pg_temp.err('delete from public.daily_puzzles where true') like 'permission denied%');
select pg_temp.ok('anon cannot read schedule', pg_temp.err('select * from public.schedule') like 'permission denied%');
select pg_temp.ok('anon cannot call freeze_puzzle', pg_temp.err($q$select public.freeze_puzzle('2099-03-09')$q$) like 'permission denied%');
select pg_temp.ok('anon cannot call freeze_upcoming', pg_temp.err('select public.freeze_upcoming()') like 'permission denied%');
select pg_temp.ok('get_daily for a date past UTC+1 returns null', public.get_daily('2099-03-01') is null);
select pg_temp.ok('get_daily(null) -> bad_input', pg_temp.err('select public.get_daily(null)') = 'bad_input');
reset role;

-- ---------- get_daily lazy freeze on the real UTC date (skipped if real puzzles exist)
do $$
declare t date := public.utc_today(); a jsonb; b jsonb;
begin
  if exists (select 1 from public.daily_puzzles where puzzle_date between t - 3 and t + 3) then
    perform pg_temp.ok('get_daily lazy-freeze checks skipped: real puzzles exist near today', true);
    return;
  end if;
  update public.config set value = to_jsonb((t - 5)::text) where key = 'launch_date';
  execute 'set local role anon';
  a := public.get_daily(t);
  b := public.get_daily(t);
  perform pg_temp.ok('get_daily(today) lazily freezes and returns the snapshot', a is not null and (a ->> 'puzzle_no')::int = 6);
  perform pg_temp.ok('get_daily(today) again returns the identical snapshot', a = b);
  perform pg_temp.ok('get_daily(today + 1) is readable (UTC+14 window)', public.get_daily(t + 1) is not null);
  perform pg_temp.ok('get_daily(today + 2) is hidden', public.get_daily(t + 2) is null);
  perform pg_temp.ok('get_daily(today - 3) is not lazily frozen', public.get_daily(t - 3) is null);
  perform pg_temp.ok('anon can read today''s row in the table', (select count(*) from public.daily_puzzles where puzzle_date = t) = 1);
  execute 'reset role';
  perform public.freeze_puzzle(t + 3);
  execute 'set local role anon';
  perform pg_temp.ok('a frozen future row (today + 3) stays hidden from anon', (select count(*) from public.daily_puzzles where puzzle_date = t + 3) = 0);
  execute 'reset role';
  perform pg_temp.ok('late_freeze logged for the lazy freeze', exists (select 1 from public.ops_log where kind = 'late_freeze' and detail ->> 'date' = t::text));
end $$;

-- ---------- cron
select pg_temp.ok('cron job goat-freeze scheduled at 00:05 UTC',
  exists (select 1 from cron.job where jobname = 'goat-freeze' and schedule = '5 0 * * *' and active
            and command like '%public.freeze_upcoming()%'));

select test, ok, detail from _r order by at;
rollback;
