-- Rollback for 0016_crawlers_not_players.sql: track() goes back to the 0009 version (crawlers' events are
-- stored again), site_stats_daily to the 0012 version (listed crawlers counted again), and the crawler list
-- and request_is_crawler() are removed. Events stored meanwhile are not touched.
create or replace function public.track(p_events jsonb) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  e       jsonb;
  v_rows  integer;
  v_allow text[] := array['visit', 'game_start', 'game_complete', 'pick_vote', 'share',
                          'practice_start', 'suggest', 'vote_error', 'offline',
                          'hint', 'give_up', 'take_post'];
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

create or replace function public.site_stats_daily(p_token text, p_start date, p_end date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_hash text;
  v_from timestamptz;
  v_to   timestamptz;
begin
  select s.value into v_hash from public.secrets s where s.key = 'site_stats_token_sha256';
  if p_token is null or v_hash is null or v_hash <> encode(sha256(convert_to(p_token, 'UTF8')), 'hex') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_start is null or p_end is null or p_end < p_start or p_end - p_start > 800 then
    raise exception 'bad date range' using errcode = '22023';
  end if;

  v_from := p_start::timestamp at time zone 'America/Los_Angeles';
  v_to   := (p_end + 1)::timestamp at time zone 'America/Los_Angeles';

  return (
    with firsts as (
      select player, (min(at) at time zone 'America/Los_Angeles')::date as joined
        from public.events e0
       where not exists (select 1 from public.site_stats_left_out l where l.player = e0.player)
       group by player
    ),
    ev as (
      select player, event, puzzle_no, (at at time zone 'America/Los_Angeles')::date as day
        from public.events e1
       where at >= v_from and at < v_to
         and not exists (select 1 from public.site_stats_left_out l where l.player = e1.player)
    ),
    days as (
      select d::date as day from generate_series(p_start::timestamp, p_end::timestamp, interval '1 day') d
    ),
    per_day as (
      select d.day,
             (select count(*) from firsts f where f.joined = d.day) as new_visitors,
             (select count(distinct e.player) from ev e where e.day = d.day) as visitors,
             (select count(distinct e.player) from ev e
               where e.day = d.day and e.event in ('game_start', 'practice_start')) as played,
             (select count(distinct (e.player, e.puzzle_no)) from ev e
               where e.day = d.day and e.event = 'game_complete' and e.puzzle_no is not null) as finished
        from days d
    )
    select jsonb_build_object(
      'start', to_char(p_start, 'YYYY-MM-DD'),
      'end',   to_char(p_end, 'YYYY-MM-DD'),
      'days', (select coalesce(jsonb_agg(jsonb_build_object(
                  'date', to_char(p.day, 'YYYY-MM-DD'),
                  'new_visitors', p.new_visitors,
                  'visitors', p.visitors,
                  'played', p.played,
                  'finished', p.finished) order by p.day), '[]'::jsonb)
                 from per_day p),
      'new_visitors',   (select count(*) from firsts where joined between p_start and p_end),
      'visitors',       (select count(distinct player) from ev),
      'played',         (select count(distinct player) from ev where event in ('game_start', 'practice_start')),
      'finished',       (select count(distinct (player, puzzle_no)) from ev
                          where event = 'game_complete' and puzzle_no is not null),
      'visitors_total', (select count(*) from firsts where joined <= p_end)
    )
  );
end $$;

revoke all on function public.site_stats_daily(text, date, date) from public, anon, authenticated;
grant execute on function public.site_stats_daily(text, date, date) to anon;

drop function if exists public.request_is_crawler();
drop table if exists public.site_stats_crawlers;
