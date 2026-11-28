-- SQL tests for 0016_crawlers_not_players.sql. One transaction, rolled back. Synthetic events are dated 2001
-- (counts) or now (track), with throwaway player IDs; a throwaway token hash is swapped in inside the
-- transaction only. request.headers is set the way PostgREST sets it for a web request.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.ev(p_player text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('event_id', gen_random_uuid(), 'player', p_player, 'event', 'visit',
                                              'props', jsonb_build_object('first_visit', true)))
$$;

insert into public.secrets (key, value) values
  ('site_stats_token_sha256', encode(sha256(convert_to('goat-stats-test-token', 'UTF8')), 'hex'))
on conflict (key) do update set value = excluded.value;

-- 2001-06-01, Pacific: a person and a listed crawler both visit; the person plays.
insert into public.events (event_id, at, player, event, puzzle_no, props) values
 (gen_random_uuid(), '2001-06-01 17:00+00', 'crawl-test-person', 'visit', null, '{}'),
 (gen_random_uuid(), '2001-06-01 17:01+00', 'crawl-test-person', 'game_start', 1, '{}'),
 (gen_random_uuid(), '2001-06-01 18:00+00', 'crawl-test-listed', 'visit', null, '{}');

-- ---------- track() as anon, the way the game calls it
set local role anon;
select set_config('request.headers', '{"user-agent": "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.8103.78 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"}', true);
select pg_temp.ok('Googlebot -> 0 stored', (select public.track(pg_temp.ev('crawl-test-googlebot'))) = 0);
select set_config('request.headers', '{"user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36 WaybackMachineLabs-NewWeb/0.1 (Internet Archive; +https://wayback-labs.sf.archive.org/new-web/)"}', true);
select pg_temp.ok('Wayback crawler -> 0 stored', (select public.track(pg_temp.ev('crawl-test-wayback'))) = 0);
select set_config('request.headers', '{"user-agent": "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.8103.78 Mobile Safari/537.36 (compatible; Google-InspectionTool/1.0)"}', true);
select pg_temp.ok('Search Console test -> 0 stored', (select public.track(pg_temp.ev('crawl-test-inspect'))) = 0);
select set_config('request.headers', '{"user-agent": ""}', true);
select pg_temp.ok('empty user agent -> 0 stored', (select public.track(pg_temp.ev('crawl-test-empty-ua'))) = 0);
select set_config('request.headers', '{"user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Mobile/15E148 Safari/604.1"}', true);
select pg_temp.ok('iPhone Safari -> 1 stored', (select public.track(pg_temp.ev('crawl-test-iphone'))) = 1);
select set_config('request.headers', '{"user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/158.0.0.0 Safari/537.36 Edg/158.0.0.0"}', true);
select pg_temp.ok('Edge on Windows -> 1 stored', (select public.track(pg_temp.ev('crawl-test-edge'))) = 1);
select pg_temp.ok('a browser''s bad input is still refused', pg_temp.err($q$select public.track('[]'::jsonb)$q$) = 'bad_input');
select pg_temp.ok('anon cannot read the crawler list', pg_temp.err('select * from public.site_stats_crawlers') like 'permission denied%');
select pg_temp.ok('anon cannot call request_is_crawler', pg_temp.err('select public.request_is_crawler()') like 'permission denied%');
select set_config('request.headers', '', true);
create temp table _before on commit drop as
  select public.site_stats_daily('goat-stats-test-token', '2001-06-01', '2001-06-01') as r;
reset role;

insert into public.site_stats_crawlers (player, why) values ('crawl-test-listed', 'test');
set local role anon;
create temp table _after on commit drop as
  select public.site_stats_daily('goat-stats-test-token', '2001-06-01', '2001-06-01') as r;
reset role;

-- ---------- not a web request (SQL editor, scheduled jobs): no request.headers, stored as before
select pg_temp.ok('no request headers -> stored', (select public.track(pg_temp.ev('crawl-test-internal'))) = 1);

select pg_temp.ok('crawler events were not stored',
  (select count(*) = 0 from public.events where player in ('crawl-test-googlebot', 'crawl-test-wayback', 'crawl-test-inspect', 'crawl-test-empty-ua')));
select pg_temp.ok('browser events were stored',
  (select count(*) = 3 from public.events where player in ('crawl-test-iphone', 'crawl-test-edge', 'crawl-test-internal')));
select pg_temp.ok('before the list: 2 new visitors, 2 visitors, 1 played',
  (select r -> 'days' -> 0 from _before) = '{"date": "2001-06-01", "new_visitors": 2, "visitors": 2, "played": 1, "finished": 0}'::jsonb,
  (select (r -> 'days' -> 0)::text from _before));
select pg_temp.ok('after the list: only the person counts',
  (select r -> 'days' -> 0 from _after) = '{"date": "2001-06-01", "new_visitors": 1, "visitors": 1, "played": 1, "finished": 0}'::jsonb,
  (select (r -> 'days' -> 0)::text from _after));
select pg_temp.ok('the listed crawler''s events are still there', (select count(*) = 1 from public.events where player = 'crawl-test-listed'));

select test, ok, detail from _r order by at;
rollback;
