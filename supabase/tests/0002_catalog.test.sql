-- SQL tests for 0002_catalog.sql. Runs inside one transaction that is rolled back; nothing persists.
-- Returns one row per check (test, ok, detail). Roles: postgres (setup), anon (public API).
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.rank_of(p_slug text, p_name text) returns integer language sql as $$
  select (e ->> 'rank')::integer from jsonb_array_elements(public.ranking_of(p_slug) -> 'ranking') e where e ->> 'name' = p_name $$;
create function pg_temp.blend_of(p_slug text, p_name text) returns numeric language sql as $$
  select (e ->> 'blended')::numeric from jsonb_array_elements(public.ranking_of(p_slug) -> 'ranking') e where e ->> 'name' = p_name $$;

-- ---------- fixtures (postgres). Existing categories are hidden for the test only.
update public.catalog set active = false where active;
insert into public.catalog (slug, name, title, kind, opts, clues, source) values
 ('test-a', 'Test A', 'GOAT test A', 'daily',
  '[{"name":"Alpha","est":0.30},{"name":"Bravo","est":0.20},{"name":"Charlie","est":0.15},{"name":"Delta","est":0.10},
    {"name":"Echo","est":0.08},{"name":"Foxtrot","est":0.06},{"name":"Golf","est":0.03},{"name":"Hotel","est":0.03},
    {"name":"India","est":0.02},{"name":"Juliet","est":0.02},{"name":"Kilo","est":0},{"name":"Lima","est":0},
    {"name":"Mike","est":0},{"name":"November","est":0},{"name":"Oscar","est":0},{"name":"Papa","est":0}]',
  '{"Alpha":["a1","a2","a3","a4"],"Bravo":["b1","b2","b3","b4"],"Charlie":["c1","c2","c3","c4"]}', 'builtin'),
 ('test-off', 'Test Off', 'GOAT test off', 'vote',
  '[{"name":"W","est":0},{"name":"X","est":0},{"name":"Y","est":0},{"name":"Z","est":0}]', '{}', 'community');
update public.catalog set active = false where slug = 'test-off';

-- ---------- RLS / grants as anon
set local role anon;
select pg_temp.ok('anon reads public config (k)', (select count(*) from public.config where key = 'k') = 1);
select pg_temp.ok('anon cannot see private config (rate_limits)', (select count(*) from public.config where key = 'rate_limits') = 0);
select pg_temp.ok('anon cannot read secrets', pg_temp.err('select * from public.secrets') like 'permission denied%');
select pg_temp.ok('anon cannot read catalog_votes', pg_temp.err('select * from public.catalog_votes') like 'permission denied%');
select pg_temp.ok('anon cannot read rate_limits', pg_temp.err('select * from public.rate_limits') like 'permission denied%');
select pg_temp.ok('anon cannot read ops_log', pg_temp.err('select * from public.ops_log') like 'permission denied%');
select pg_temp.ok('anon cannot insert catalog', pg_temp.err($q$insert into public.catalog (slug,name,title,kind,opts,source) values ('x-x','x','x','vote','[{},{},{},{}]','community')$q$) like 'permission denied%');
select pg_temp.ok('anon cannot update config', pg_temp.err($q$update public.config set value = '0' where key = 'k'$q$) like 'permission denied%');
select pg_temp.ok('anon cannot delete vote_counts', pg_temp.err('delete from public.vote_counts where true') like 'permission denied%');
select pg_temp.ok('anon cannot insert catalog_votes directly', pg_temp.err($q$insert into public.catalog_votes values ('test-a','player-zz-01','Alpha')$q$) like 'permission denied%');
select pg_temp.ok('anon sees active categories only', (select count(*) from public.catalog where slug in ('test-a','test-off')) = 1);
select pg_temp.ok('anon cannot call internal cfg()', pg_temp.err($q$select public.cfg('k')$q$) like 'permission denied%');
select pg_temp.ok('anon cannot call check_rate()', pg_temp.err($q$select public.check_rate('vote','x',1,'1 hour')$q$) like 'permission denied%');
select pg_temp.ok('anon cannot call refresh_vote_counts()', pg_temp.err('select public.refresh_vote_counts()') like 'permission denied%');
select pg_temp.ok('old categories table is gone', pg_temp.err('select * from public.categories') like '%does not exist%');
select pg_temp.ok('get_catalog returns active test-a only',
  (select count(*) from jsonb_array_elements(public.get_catalog()) e where e ->> 'slug' in ('test-a','test-off')) = 1);
select pg_temp.ok('get_catalog: estimated tier, 0 votes, 16 ranked',
  (select e ->> 'tier' = 'estimated' and (e ->> 'total_votes')::int = 0 and jsonb_array_length(e -> 'ranking') = 16
     from jsonb_array_elements(public.get_catalog()) e where e ->> 'slug' = 'test-a'));
reset role;

-- ---------- blended ranking (§3) at V = 0, 1, 150, 499, 500, 5000 (all real votes on Bravo, est 0.20)
select pg_temp.ok('V=0: Alpha #1, b = e',
  pg_temp.rank_of('test-a','Alpha') = 1 and pg_temp.blend_of('test-a','Alpha') = 0.300000
  and public.tier_of(0) = 'estimated');
select pg_temp.ok('V=0 ties: equal e ordered by name (Golf, Hotel, India, Juliet)',
  pg_temp.rank_of('test-a','Golf') = 7 and pg_temp.rank_of('test-a','Hotel') = 8
  and pg_temp.rank_of('test-a','India') = 9 and pg_temp.rank_of('test-a','Juliet') = 10);
select pg_temp.ok('V=0: zero-estimate contenders ordered by name after the top 10',
  pg_temp.rank_of('test-a','Kilo') = 11 and pg_temp.rank_of('test-a','Papa') = 16);

do $$
declare
  v integer;
  r jsonb;
begin
  foreach v in array array[1, 150, 499, 500, 5000] loop
    delete from public.catalog_votes where slug = 'test-a';
    insert into public.catalog_votes (slug, player, pick)
      select 'test-a', 'tplayer-' || lpad(g::text, 6, '0'), 'Bravo' from generate_series(1, v) g;
    r := public.ranking_of('test-a');
    perform pg_temp.ok(format('V=%s: total_votes and tier label', v),
      (r ->> 'total_votes')::int = v
      and public.tier_of(v) = case when v < 500 then 'blended' else 'community' end,
      format('total=%s tier=%s', r ->> 'total_votes', public.tier_of(v)));
    perform pg_temp.ok(format('V=%s: b = (v + k*e)/(V + k) for Bravo and Alpha', v),
      pg_temp.blend_of('test-a','Bravo') = round((v + 100 * 0.20) / (v + 100.0), 6)
      and pg_temp.blend_of('test-a','Alpha') = round((0 + 100 * 0.30) / (v + 100.0), 6),
      format('Bravo=%s Alpha=%s', pg_temp.blend_of('test-a','Bravo'), pg_temp.blend_of('test-a','Alpha')));
    perform pg_temp.ok(format('V=%s: correct #1', v),
      pg_temp.rank_of('test-a', case when v > 10 then 'Bravo' else 'Alpha' end) = 1);
  end loop;
  -- Equal b, different e: Juliet (1 vote, e .02) ties Golf/Hotel (0 votes, e .03) at 3/101; higher e wins.
  delete from public.catalog_votes where slug = 'test-a';
  insert into public.catalog_votes (slug, player, pick) values ('test-a', 'tplayer-tie-1', 'Juliet');
  perform pg_temp.ok('equal b: higher e first, then name (Golf, Hotel, Juliet, India)',
    pg_temp.rank_of('test-a','Golf') = 7 and pg_temp.rank_of('test-a','Hotel') = 8
    and pg_temp.rank_of('test-a','Juliet') = 9 and pg_temp.rank_of('test-a','India') = 10);
  delete from public.catalog_votes where slug = 'test-a';
  perform pg_temp.ok('vote_counts empty after deleting all votes', not exists (select 1 from public.vote_counts where slug = 'test-a'));
end $$;

-- ---------- cast_vote as anon (one row per player; change = same row; retry = no duplicate)
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.10, 10.0.0.1"}', true);
set local role anon;
select pg_temp.ok('cast_vote ok', pg_temp.err($q$select public.cast_vote('player-vote-0001','test-a','Alpha')$q$) = 'ok');
reset role;
select pg_temp.ok('pick creates one catalog_votes row',
  (select count(*) from public.catalog_votes where slug = 'test-a' and player = 'player-vote-0001') = 1);
select pg_temp.ok('vote_counts Alpha = 1', (select n from public.vote_counts where slug = 'test-a' and pick = 'Alpha') = 1);
set local role anon;
select pg_temp.ok('change vote ok', pg_temp.err($q$select public.cast_vote('player-vote-0001','test-a','Bravo')$q$) = 'ok');
select pg_temp.ok('vote_counts visible to anon: Bravo 1, Alpha gone',
  (select n from public.vote_counts where slug = 'test-a' and pick = 'Bravo') = 1
  and not exists (select 1 from public.vote_counts where slug = 'test-a' and pick = 'Alpha'));
select pg_temp.ok('retry same pick ok', pg_temp.err($q$select public.cast_vote('player-vote-0001','test-a','Bravo')$q$) = 'ok');
reset role;
select pg_temp.ok('change/retry: still one row, pick changed, count unchanged',
  (select count(*) from public.catalog_votes where slug = 'test-a') = 1
  and (select pick from public.catalog_votes where player = 'player-vote-0001') = 'Bravo'
  and (select sum(n) from public.vote_counts where slug = 'test-a') = 1);
do $$
declare before jsonb; after jsonb;
begin
  select jsonb_agg(to_jsonb(v) order by slug, pick) into before from public.vote_counts v;
  perform public.refresh_vote_counts();
  select jsonb_agg(to_jsonb(v) order by slug, pick) into after from public.vote_counts v;
  perform pg_temp.ok('refresh_vote_counts matches trigger-maintained counts', before is not distinct from after);
end $$;
select pg_temp.ok('ip stored only as a 64-char hash',
  exists (select 1 from public.rate_limits where bucket = 'vote' and ip_hash ~ '^[0-9a-f]{64}$')
  and not exists (select 1 from public.rate_limits where ip_hash like '%203.0.113%'));

set local role anon;
select pg_temp.ok('unknown pick -> bad_pick', pg_temp.err($q$select public.cast_vote('player-vote-0001','test-a','Zulu')$q$) = 'bad_pick');
select pg_temp.ok('inactive category -> bad_pick', pg_temp.err($q$select public.cast_vote('player-vote-0001','test-off','W')$q$) = 'bad_pick');
select pg_temp.ok('short player id -> bad_input', pg_temp.err($q$select public.cast_vote('short','test-a','Alpha')$q$) = 'bad_input');
reset role;

-- ---------- rate limit: 120 votes/hour per IP hash; the 121st is rate_limited
select set_config('request.headers', '{"x-forwarded-for":"198.51.100.77"}', true);
set local role anon;
do $$
declare i integer; bad integer := 0;
begin
  for i in 1..120 loop
    if pg_temp.err(format($q$select public.cast_vote('rl-player-%s','test-a','Alpha')$q$, lpad(i::text, 4, '0'))) <> 'ok' then
      bad := bad + 1;
    end if;
  end loop;
  perform pg_temp.ok('120 votes from one IP all succeed', bad = 0, format('%s failed', bad));
  perform pg_temp.ok('121st vote from same IP -> rate_limited',
    pg_temp.err($q$select public.cast_vote('rl-player-0121','test-a','Alpha')$q$) = 'rate_limited');
end $$;
reset role;
select set_config('request.headers', '{"x-forwarded-for":"198.51.100.78"}', true);
set local role anon;
select pg_temp.ok('a different IP is not limited', pg_temp.err($q$select public.cast_vote('rl-player-0122','test-a','Alpha')$q$) = 'ok');
reset role;
select set_config('request.headers', '', true);
set local role anon;
select pg_temp.ok('missing IP still votes', pg_temp.err($q$select public.cast_vote('rl-player-0123','test-a','Alpha')$q$) = 'ok');
reset role;
select pg_temp.ok('missing IP uses bucket ip:unknown', exists (select 1 from public.rate_limits where bucket = 'vote' and ip_hash = 'ip:unknown'));

-- ---------- kill switch
update public.config set value = 'false' where key = 'voting_enabled';
set local role anon;
select pg_temp.ok('voting_enabled=false -> disabled', pg_temp.err($q$select public.cast_vote('player-vote-0002','test-a','Alpha')$q$) = 'disabled');
select pg_temp.ok('gameplay reads unaffected when voting is off', jsonb_array_length(public.get_catalog()) >= 1);
reset role;

select test, ok, detail from _r order by at;
rollback;
