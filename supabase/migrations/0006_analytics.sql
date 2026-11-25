-- 0006_analytics.sql  (HANDOFF §5, §9, §10, §7 owner stats)
-- events (unique client event_id), track(), reporting views (schema "reports", not exposed by the API),
-- owner_stats, owner_delete_player (§10 deletion requests), and the nightly retention cleanup job.

-- ---------------------------------------------------------------- events
create table public.events (
  event_id  uuid primary key,
  at        timestamptz not null default now(),
  player    text not null check (char_length(player) between 8 and 64),
  event     text not null check (event in ('visit', 'game_start', 'game_complete', 'pick_vote', 'share',
                                           'practice_start', 'suggest', 'vote_error', 'offline')),
  puzzle_no integer,
  ref       text check (ref is null or char_length(ref) between 8 and 64),
  props     jsonb not null default '{}'::jsonb check (jsonb_typeof(props) = 'object' and octet_length(props::text) <= 2048)
);
create index events_at_idx on public.events (at);
create index events_player_idx on public.events (player, at);
create index events_event_idx on public.events (event, at);
alter table public.events enable row level security;
revoke all on public.events from anon, authenticated;

-- ---------------------------------------------------------------- track (public)
-- p_events: a JSON array of 1-50 events: {event_id (uuid), player, event, puzzle_no?, ref?, props?, at?}.
-- ref = the player's own referral code; an incoming ?r= code goes in props.ref on "visit".
-- at = client time, accepted only within the last 7 days (queued offline events); otherwise server time.
-- Any invalid event rejects the batch with bad_input. Resent event_ids are ignored. Returns rows stored.
create function public.track(p_events jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  e       jsonb;
  v_rows  integer;
  v_allow text[] := array['visit', 'game_start', 'game_complete', 'pick_vote', 'share',
                          'practice_start', 'suggest', 'vote_error', 'offline'];
begin
  if not public.enabled('analytics_enabled') then
    raise exception 'disabled';
  end if;
  if jsonb_typeof(p_events) is distinct from 'array' or jsonb_array_length(p_events) not between 1 and 50 then
    raise exception 'bad_input';
  end if;
  for e in select value from jsonb_array_elements(p_events) loop
    if jsonb_typeof(e) <> 'object'
       or coalesce(e ->> 'event_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or char_length(coalesce(e ->> 'player', '')) not between 8 and 64
       or coalesce(e ->> 'event', '') <> all (v_allow)
       or ((e ->> 'ref') is not null and char_length(e ->> 'ref') not between 8 and 64)
       or ((e ->> 'puzzle_no') is not null and (jsonb_typeof(e -> 'puzzle_no') <> 'number'
            or (e ->> 'puzzle_no')::numeric <> trunc((e ->> 'puzzle_no')::numeric)
            or (e ->> 'puzzle_no')::numeric not between 1 and 1000000))
       or (e ? 'props' and jsonb_typeof(e -> 'props') not in ('object', 'null'))
       or octet_length(coalesce(nullif(e -> 'props', 'null'::jsonb), '{}'::jsonb)::text) > 2048
       or ((e ->> 'at') is not null and coalesce(e ->> 'at', '') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$')
    then
      raise exception 'bad_input';
    end if;
  end loop;

  perform public.enforce_rate('track', jsonb_array_length(p_events));

  insert into public.events (event_id, at, player, event, puzzle_no, ref, props)
  select (x ->> 'event_id')::uuid,
         case when (x ->> 'at') is not null
                   and (x ->> 'at')::timestamptz between now() - interval '7 days' and now()
              then (x ->> 'at')::timestamptz else now() end,
         x ->> 'player', x ->> 'event', (x ->> 'puzzle_no')::integer, x ->> 'ref',
         coalesce(nullif(x -> 'props', 'null'::jsonb), '{}'::jsonb)
    from jsonb_array_elements(p_events) as x
  on conflict (event_id) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows;
end $$;

-- ---------------------------------------------------------------- reporting views (SQL only, §9)
-- Days are UTC. The schema is not exposed through the API and has no grants to anon/authenticated.
create schema if not exists reports;
revoke all on schema reports from public, anon, authenticated;

create view reports.daily_players with (security_invoker = true) as
select (e.at at time zone 'utc')::date as day, count(distinct e.player) as players
  from public.events e group by 1;

create view reports.returning_players with (security_invoker = true) as
with f as (select player, min((at at time zone 'utc')::date) as first_day from public.events group by player)
select (e.at at time zone 'utc')::date as day,
       count(distinct e.player) as players,
       count(distinct e.player) filter (where f.first_day < (e.at at time zone 'utc')::date) as returning_players
  from public.events e join f using (player) group by 1;

create view reports.retention with (security_invoker = true) as
with f as (
  select player, min((at at time zone 'utc')::date) as d0 from public.events where event = 'visit' group by player
), a as (
  select distinct player, (at at time zone 'utc')::date as d from public.events
), c as (
  select f.d0,
         count(*) as cohort_size,
         count(*) filter (where exists (select 1 from a where a.player = f.player and a.d = f.d0 + 1))  as d1,
         count(*) filter (where exists (select 1 from a where a.player = f.player and a.d = f.d0 + 7))  as d7,
         count(*) filter (where exists (select 1 from a where a.player = f.player and a.d = f.d0 + 30)) as d30
    from f group by f.d0
)
select d0 as cohort_day, cohort_size, d1, d7, d30,
       round(100.0 * d1 / cohort_size, 1) as d1_pct,
       round(100.0 * d7 / cohort_size, 1) as d7_pct,
       round(100.0 * d30 / cohort_size, 1) as d30_pct
  from c;

-- Daily games only (events with a puzzle_no). One game = one (player, puzzle_no).
create view reports.games with (security_invoker = true) as
select day, started, completed,
       round(100.0 * completed / nullif(started, 0), 1) as completion_rate_pct,
       avg_guesses
  from (select (at at time zone 'utc')::date as day,
               count(distinct (player, puzzle_no)) filter (where event = 'game_start')    as started,
               count(distinct (player, puzzle_no)) filter (where event = 'game_complete') as completed,
               round(avg((props ->> 'guesses')::numeric) filter (where event = 'game_complete'), 2) as avg_guesses
          from public.events where puzzle_no is not null group by 1) s;

create view reports.completed_with_pick with (security_invoker = true) as
with c as (
  select player, puzzle_no, (min(at) at time zone 'utc')::date as day
    from public.events where event = 'game_complete' and puzzle_no is not null group by player, puzzle_no
)
select day, count(*) as completed,
       count(*) filter (where exists (select 1 from public.events p
                                       where p.event = 'pick_vote' and p.player = c.player
                                         and p.puzzle_no = c.puzzle_no)) as with_pick,
       round(100.0 * count(*) filter (where exists (select 1 from public.events p
                                       where p.event = 'pick_vote' and p.player = c.player
                                         and p.puzzle_no = c.puzzle_no)) / count(*), 1) as pick_pct
  from c group by day;

create view reports.shares_per_completion with (security_invoker = true) as
select (at at time zone 'utc')::date as day,
       count(*) filter (where event = 'share') as shares,
       count(distinct (player, puzzle_no)) filter (where event = 'game_complete' and puzzle_no is not null) as completed,
       round(count(*) filter (where event = 'share')::numeric
             / nullif(count(distinct (player, puzzle_no)) filter (where event = 'game_complete' and puzzle_no is not null), 0), 2)
         as shares_per_completed_game
  from public.events group by 1;

create view reports.referral_visits with (security_invoker = true) as
select (at at time zone 'utc')::date as day, count(*) as referral_visits, count(distinct player) as referred_players
  from public.events where event = 'visit' and (props ->> 'ref') is not null group by 1;

create view reports.referred_first_visits with (security_invoker = true) as
with fv as (
  select distinct on (player) player, at, props ->> 'ref' as ref
    from public.events where event = 'visit' order by player, at
)
select (fv.at at time zone 'utc')::date as day,
       count(*) as referred_first_visits,
       count(*) filter (where exists (select 1 from public.events g
                                       where g.player = fv.player and g.event = 'game_complete')) as reached_complete,
       round(100.0 * count(*) filter (where exists (select 1 from public.events g
                                       where g.player = fv.player and g.event = 'game_complete')) / count(*), 1)
         as reached_complete_pct
  from fv where fv.ref is not null group by 1;

create view reports.daily_vote_volume with (security_invoker = true) as
select coalesce(n.day, p.day) as day, coalesce(n.new_votes, 0) as new_votes, coalesce(p.pick_events, 0) as pick_events
  from (select (created_at at time zone 'utc')::date as day, count(*) as new_votes
          from public.catalog_votes group by 1) n
  full join (select (at at time zone 'utc')::date as day, count(*) as pick_events
               from public.events where event = 'pick_vote' group by 1) p on p.day = n.day;

revoke all on all tables in schema reports from public, anon, authenticated;

-- ---------------------------------------------------------------- owner functions
create function public.owner_stats(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_today timestamptz := (public.utc_today())::timestamp at time zone 'utc';
begin
  perform public.require_owner(p_token);
  return jsonb_build_object(
    'day', public.utc_today(),
    'players',     (select count(distinct player) from public.events where at >= v_today),
    'completions', (select count(*) from public.events where at >= v_today and event = 'game_complete'),
    'votes',       (select count(*) from public.catalog_votes where updated_at >= v_today),
    'shares',      (select count(*) from public.events where at >= v_today and event = 'share'),
    'top_ip_hashes', coalesce((
        select jsonb_agg(jsonb_build_object('ip_hash', ip_hash, 'requests', requests) order by requests desc)
          from (select ip_hash, sum(count)::integer as requests from public.rate_limits
                 where window_start >= now() - interval '24 hours'
                 group by ip_hash order by 2 desc limit 10) t), '[]'::jsonb));
end $$;

-- §10 deletion request: removes a player's votes, suggestions and events. Counts recompute by trigger.
create function public.owner_delete_player(p_token text, p_player text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_votes integer; v_sugg integer; v_events integer;
begin
  perform public.require_owner(p_token);
  if char_length(coalesce(p_player, '')) not between 8 and 64 then
    raise exception 'bad_input';
  end if;
  delete from public.catalog_votes where player = p_player; get diagnostics v_votes = row_count;
  delete from public.suggestions where voter = p_player;    get diagnostics v_sugg = row_count;
  delete from public.events where player = p_player;        get diagnostics v_events = row_count;
  insert into public.ops_log (kind, detail)
    values ('player_deleted', jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events));
  return jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events);
end $$;

-- ---------------------------------------------------------------- retention (§10, §17)
-- events 13 months; rate_limits 48 hours; suggestions deleted once reviewed (added) or 90 days after
-- dismissal; expired owner sessions after 30 days; backup.* tables after 14 days.
create function public.cleanup_retention() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_events integer; v_rates integer; v_added integer; v_dismissed integer; v_sessions integer;
  v_backups integer := 0;
  r record;
begin
  delete from public.events where at < now() - interval '13 months';               get diagnostics v_events = row_count;
  delete from public.rate_limits where window_start < now() - interval '48 hours';  get diagnostics v_rates = row_count;
  delete from public.suggestions where status = 'added';                           get diagnostics v_added = row_count;
  delete from public.suggestions
   where status = 'dismissed' and coalesce(reviewed_at, created_at) < now() - interval '90 days';
  get diagnostics v_dismissed = row_count;
  delete from public.owner_sessions where expires_at < now() - interval '30 days'; get diagnostics v_sessions = row_count;
  for r in
    select c.relname from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'backup' and c.relkind = 'r'
       and substring(c.relname from '_(\d{8})(_\d{4})?$') is not null
       and to_date(substring(c.relname from '_(\d{8})(_\d{4})?$'), 'YYYYMMDD') < public.utc_today() - 14
  loop
    execute format('drop table backup.%I', r.relname);
    v_backups := v_backups + 1;
  end loop;
  insert into public.ops_log (kind, detail) values ('cleanup', jsonb_build_object(
    'events', v_events, 'rate_limits', v_rates, 'suggestions_added', v_added,
    'suggestions_dismissed', v_dismissed, 'owner_sessions', v_sessions, 'backups', v_backups));
  return jsonb_build_object('events', v_events, 'rate_limits', v_rates, 'suggestions_added', v_added,
    'suggestions_dismissed', v_dismissed, 'owner_sessions', v_sessions, 'backups', v_backups);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.track(jsonb), public.owner_stats(text), public.owner_delete_player(text, text),
  public.cleanup_retention()
from public, anon, authenticated;
grant execute on function public.track(jsonb), public.owner_stats(text), public.owner_delete_player(text, text)
to anon, authenticated;

-- ---------------------------------------------------------------- cron
select cron.schedule('goat-cleanup', '20 3 * * *', $cron$select public.cleanup_retention()$cron$);
