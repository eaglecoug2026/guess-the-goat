-- SQL tests for 0006_analytics.sql. One transaction, rolled back. The reporting checks use synthetic events
-- dated 2001 so they never mix with real data.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
create temp table _tok (name text primary key, token text) on commit drop;
grant all on _r, _tok to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.tok(p_name text) returns text language sql as $$ select token from _tok where name = p_name $$;
create function pg_temp.ev(p_event text, p_extra jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('event_id', gen_random_uuid(), 'player', 'player-ev-0001', 'event', p_event) || p_extra $$;

update public.secrets set value = extensions.crypt('goat-test-pass-1', extensions.gen_salt('bf', 4)) where key = 'owner_pass_hash';
insert into public.catalog (slug, name, title, kind, opts, source) values
 ('test-ev', 'Test EV', 'GOAT test ev', 'vote', '[{"name":"W","est":0},{"name":"X","est":0},{"name":"Y","est":0},{"name":"Z","est":0}]', 'builtin');

-- ---------- track as anon
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.90"}', true);
set local role anon;
select pg_temp.ok('anon cannot read events', pg_temp.err('select * from public.events') like 'permission denied%');
select pg_temp.ok('anon cannot read the reports schema', pg_temp.err('select * from reports.games') like 'permission denied%');
select pg_temp.ok('anon cannot call cleanup_retention', pg_temp.err('select public.cleanup_retention()') like 'permission denied%');
select pg_temp.ok('track one visit -> 1 stored', public.track(jsonb_build_array(jsonb_build_object(
  'event_id', '11111111-1111-4111-8111-111111111111', 'player', 'player-ev-0001', 'event', 'visit',
  'ref', 'myref001', 'props', jsonb_build_object('ref', 'abcd1234', 'referrer_domain', 'example.com', 'standalone', false, 'first_visit', true)))) = 1);
select pg_temp.ok('resending the same event_id stores nothing', public.track(jsonb_build_array(jsonb_build_object(
  'event_id', '11111111-1111-4111-8111-111111111111', 'player', 'player-ev-0001', 'event', 'visit'))) = 0);
select pg_temp.ok('batch of 3 allowlisted events -> 3', public.track(jsonb_build_array(
  pg_temp.ev('game_start', '{"puzzle_no": 1}'), pg_temp.ev('game_complete', '{"puzzle_no": 1, "props": {"won": true, "guesses": 2}}'),
  pg_temp.ev('share', '{"puzzle_no": 1, "props": {"method": "clipboard", "spoiler": false}}'))) = 3);
select pg_temp.ok('unknown event name -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('page_view'))))= 'bad_input');
select pg_temp.ok('bad event_id -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit', '{"event_id": "not-a-uuid"}')))) = 'bad_input');
select pg_temp.ok('short player -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit', '{"player": "short"}')))) = 'bad_input');
select pg_temp.ok('short ref -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit', '{"ref": "abc"}')))) = 'bad_input');
select pg_temp.ok('fractional puzzle_no -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('game_start', '{"puzzle_no": 1.5}')))) = 'bad_input');
select pg_temp.ok('props over 2 KB -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit', jsonb_build_object('props', jsonb_build_object('x', repeat('y', 2100))))))) = 'bad_input');
select pg_temp.ok('props not an object -> bad_input', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit', '{"props": [1]}')))) = 'bad_input');
select pg_temp.ok('not an array -> bad_input', pg_temp.err($q$select public.track('{"event":"visit"}')$q$) = 'bad_input');
select pg_temp.ok('empty array -> bad_input', pg_temp.err($q$select public.track('[]')$q$) = 'bad_input');
select pg_temp.ok('51 events -> bad_input', pg_temp.err(format('select public.track(%L)', (select jsonb_agg(pg_temp.ev('visit')) from generate_series(1, 51))))) = 'bad_input');
select pg_temp.ok('client time within 7 days is kept, older is replaced',
  public.track(jsonb_build_array(
    pg_temp.ev('offline', jsonb_build_object('event_id', '22222222-2222-4222-8222-222222222222', 'props', '{"what":"daily"}',
               'at', to_char((now() - interval '2 days') at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))),
    pg_temp.ev('offline', jsonb_build_object('event_id', '33333333-3333-4333-8333-333333333333', 'props', '{"what":"vote"}',
               'at', '2000-01-01T00:00:00Z')))) = 2);
reset role;
select pg_temp.ok('stored once, with player, ref and props', (select count(*) from public.events where event_id = '11111111-1111-4111-8111-111111111111' and ref = 'myref001' and props ->> 'ref' = 'abcd1234') = 1);
select pg_temp.ok('client at kept (2 days ago) / clamped (2000 -> now)',
  (select at < now() - interval '1 day' from public.events where event_id = '22222222-2222-4222-8222-222222222222')
  and (select at = now() from public.events where event_id = '33333333-3333-4333-8333-333333333333'));

-- rate limit: 600 events per hour per IP hash
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.91"}', true);
set local role anon;
do $$
declare i integer; bad integer := 0;
begin
  for i in 1..12 loop
    if pg_temp.err(format('select public.track(%L)', (select jsonb_agg(pg_temp.ev('visit')) from generate_series(1, 50)))) <> 'ok' then bad := bad + 1; end if;
  end loop;
  perform pg_temp.ok('600 events in an hour from one IP are accepted', bad = 0, format('%s batches failed', bad));
  perform pg_temp.ok('the 601st -> rate_limited', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit')))) = 'rate_limited');
end $$;
reset role;

-- kill switch
update public.config set value = 'false' where key = 'analytics_enabled';
select set_config('request.headers', '{"x-forwarded-for":"203.0.113.92"}', true);
set local role anon;
select pg_temp.ok('analytics_enabled=false -> disabled', pg_temp.err(format('select public.track(%L)', jsonb_build_array(pg_temp.ev('visit')))) = 'disabled');
select pg_temp.ok('gameplay reads unaffected when analytics is off', pg_temp.err('select public.get_catalog()') = 'ok');
reset role;
update public.config set value = 'true' where key = 'analytics_enabled';

-- ---------- reporting views on a synthetic 2001 dataset
insert into public.events (event_id, at, player, event, puzzle_no, ref, props) values
 (gen_random_uuid(), '2001-01-01 10:00Z', 'rp-player-0001', 'visit', null, 'rpref001', '{"ref":"friend01","first_visit":true}'),
 (gen_random_uuid(), '2001-01-01 10:01Z', 'rp-player-0001', 'game_start', 1, 'rpref001', '{}'),
 (gen_random_uuid(), '2001-01-01 10:05Z', 'rp-player-0001', 'game_complete', 1, 'rpref001', '{"won":true,"guesses":3}'),
 (gen_random_uuid(), '2001-01-01 10:06Z', 'rp-player-0001', 'pick_vote', 1, 'rpref001', '{"changed":false}'),
 (gen_random_uuid(), '2001-01-01 10:07Z', 'rp-player-0001', 'share', 1, 'rpref001', '{"method":"native","spoiler":false}'),
 (gen_random_uuid(), '2001-01-01 11:00Z', 'rp-player-0002', 'visit', null, 'rpref002', '{"first_visit":true}'),
 (gen_random_uuid(), '2001-01-01 11:01Z', 'rp-player-0002', 'game_start', 1, 'rpref002', '{}'),
 (gen_random_uuid(), '2001-01-02 09:00Z', 'rp-player-0001', 'visit', null, 'rpref001', '{}'),
 (gen_random_uuid(), '2001-01-08 09:00Z', 'rp-player-0002', 'visit', null, 'rpref002', '{}');
insert into public.catalog_votes (slug, player, pick, created_at, updated_at) values ('test-ev', 'rp-player-0001', 'W', '2001-01-01 10:06Z', '2001-01-01 10:06Z');

select pg_temp.ok('daily players', (select players from reports.daily_players where day = '2001-01-01') = 2);
select pg_temp.ok('returning players', (select players = 1 and returning_players = 1 from reports.returning_players where day = '2001-01-02'));
select pg_temp.ok('D1 / D7 / D30 retention by first-visit cohort',
  (select cohort_size = 2 and d1 = 1 and d7 = 1 and d30 = 0 and d1_pct = 50.0 and d7_pct = 50.0 and d30_pct = 0
     from reports.retention where cohort_day = '2001-01-01'));
select pg_temp.ok('games started / completed / completion rate / average guesses',
  (select started = 2 and completed = 1 and completion_rate_pct = 50.0 and avg_guesses = 3.00 from reports.games where day = '2001-01-01'));
select pg_temp.ok('% of completed daily games with a pick_vote', (select completed = 1 and with_pick = 1 and pick_pct = 100.0 from reports.completed_with_pick where day = '2001-01-01'));
select pg_temp.ok('shares per completed game', (select shares = 1 and completed = 1 and shares_per_completed_game = 1.00 from reports.shares_per_completion where day = '2001-01-01'));
select pg_temp.ok('referral visits', (select referral_visits = 1 from reports.referral_visits where day = '2001-01-01'));
select pg_temp.ok('% of referred first visits reaching game_complete',
  (select referred_first_visits = 1 and reached_complete = 1 and reached_complete_pct = 100.0 from reports.referred_first_visits where day = '2001-01-01'));
select pg_temp.ok('daily vote volume', (select new_votes = 1 and pick_events = 1 from reports.daily_vote_volume where day = '2001-01-01'));

-- ---------- owner stats + player deletion
select set_config('request.headers', '{"x-forwarded-for":"192.0.2.80"}', true);
set local role anon;
insert into _tok select 'main', public.owner_login('goat-test-pass-1');
select pg_temp.ok('owner_stats without a token -> not_owner', pg_temp.err('select public.owner_stats(null)') = 'not_owner');
select pg_temp.ok('owner_stats returns today''s players, completions, votes, shares, top IP hashes',
  (select s ?& array['players','completions','votes','shares','top_ip_hashes'] and (s ->> 'players')::int >= 1
          and jsonb_array_length(s -> 'top_ip_hashes') >= 1
     from (select public.owner_stats(pg_temp.tok('main')) s) x));
select pg_temp.ok('owner_delete_player without a token -> not_owner', pg_temp.err($q$select public.owner_delete_player(null, 'rp-player-0001')$q$) = 'not_owner');
select pg_temp.ok('owner_delete_player removes votes and events',
  (select (d ->> 'votes')::int = 1 and (d ->> 'events')::int = 6
     from (select public.owner_delete_player(pg_temp.tok('main'), 'rp-player-0001') d) x));
reset role;
select pg_temp.ok('player rows gone and vote_counts updated by trigger',
  not exists (select 1 from public.events where player = 'rp-player-0001')
  and not exists (select 1 from public.catalog_votes where player = 'rp-player-0001')
  and not exists (select 1 from public.vote_counts where slug = 'test-ev'));

-- ---------- retention cleanup
insert into public.events (event_id, at, player, event) values
 ('44444444-4444-4444-8444-444444444444', now() - interval '14 months', 'old-player-001', 'visit'),
 ('55555555-5555-4555-8555-555555555555', now() - interval '12 months', 'old-player-002', 'visit');
insert into public.rate_limits (bucket, ip_hash, window_start, count) values
 ('vote', 'cleanup-test-old', now() - interval '3 days', 1), ('vote', 'cleanup-test-new', now() - interval '1 hour', 1);
insert into public.suggestions (id, name, opts, voter, status, reviewed_at, created_at) values
 ('00000000-0000-4000-8000-0000000000a1', 'Cleanup added', '{}', 'cleanup-player-1', 'added', now() - interval '1 day', now() - interval '2 days'),
 ('00000000-0000-4000-8000-0000000000a2', 'Cleanup old dismissed', '{}', 'cleanup-player-1', 'dismissed', now() - interval '100 days', now() - interval '101 days'),
 ('00000000-0000-4000-8000-0000000000a3', 'Cleanup new dismissed', '{}', 'cleanup-player-1', 'dismissed', now() - interval '10 days', now() - interval '11 days'),
 ('00000000-0000-4000-8000-0000000000a4', 'Cleanup pending', '{}', 'cleanup-player-1', 'pending', null, now() - interval '200 days');
create table backup.cleanup_test_20000101 (x int);
create table backup.cleanup_test_29990101 (x int);
select pg_temp.ok('cleanup_retention runs', pg_temp.err('select public.cleanup_retention()') = 'ok');
select pg_temp.ok('events older than 13 months deleted, 12-month-old kept',
  not exists (select 1 from public.events where event_id = '44444444-4444-4444-8444-444444444444')
  and exists (select 1 from public.events where event_id = '55555555-5555-4555-8555-555555555555'));
select pg_temp.ok('rate_limits older than 48 hours deleted, recent kept',
  not exists (select 1 from public.rate_limits where ip_hash = 'cleanup-test-old')
  and exists (select 1 from public.rate_limits where ip_hash = 'cleanup-test-new'));
select pg_temp.ok('suggestions: added deleted, dismissed > 90 days deleted, recent dismissed + pending kept',
  (select array_agg(id order by id) from public.suggestions where voter = 'cleanup-player-1')
  = array['00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000a4']::uuid[]);
select pg_temp.ok('backup tables older than 14 days dropped, newer kept',
  to_regclass('backup.cleanup_test_20000101') is null and to_regclass('backup.cleanup_test_29990101') is not null);
select pg_temp.ok('cleanup logged', exists (select 1 from public.ops_log where kind = 'cleanup'));

select pg_temp.ok('cron job goat-cleanup scheduled nightly',
  exists (select 1 from cron.job where jobname = 'goat-cleanup' and schedule = '20 3 * * *' and active
            and command like '%public.cleanup_retention()%'));

select test, ok, detail from _r order by at;
rollback;
