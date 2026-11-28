-- Rollback for 0012_site_stats_leave_me_out.sql: site_stats_daily goes back to the 0008 version (left-out
-- players counted again), and the left-out list, its function and the code's hash are removed.
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
        from public.events group by player
    ),
    ev as (
      select player, event, puzzle_no, (at at time zone 'America/Los_Angeles')::date as day
        from public.events where at >= v_from and at < v_to
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

drop function if exists public.site_stats_leave_me_out(text, text);
drop table if exists public.site_stats_left_out;
delete from public.secrets where key = 'site_stats_leave_out_sha256';
