-- 0012_site_stats_leave_me_out.sql  (DECISIONS D-35)
-- The owner's own browsers stay out of the Site Stats numbers. The Site Stats page on proctorpilot.com
-- links to the game with #leave-me-out=CODE; visit.js then calls site_stats_leave_me_out(code, player ID),
-- which puts that player ID on site_stats_left_out, and site_stats_daily skips those IDs in every count.
-- The code lives only on the ProctorPilot server; this database keeps its SHA-256 in
-- secrets.site_stats_leave_out_sha256 (set outside the repo, like the other secrets). Without it every
-- call is refused. Events are not changed or deleted; the owner panel and the SQL reports still see them.

create table public.site_stats_left_out (
  player   text primary key check (length(player) between 8 and 64),
  added_at timestamptz not null default now()
);
alter table public.site_stats_left_out enable row level security;
revoke all on public.site_stats_left_out from public, anon, authenticated;

create function public.site_stats_leave_me_out(p_code text, p_player text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_hash text;
begin
  select s.value into v_hash from public.secrets s where s.key = 'site_stats_leave_out_sha256';
  if p_code is null or v_hash is null or v_hash <> encode(sha256(convert_to(p_code, 'UTF8')), 'hex') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_player is null or length(p_player) < 8 or length(p_player) > 64 then
    raise exception 'bad_input' using errcode = '22023';
  end if;
  insert into public.site_stats_left_out (player) values (p_player) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.site_stats_leave_me_out(text, text) from public, anon, authenticated;
grant execute on function public.site_stats_leave_me_out(text, text) to anon;

-- site_stats_daily from 0008, unchanged except that left-out player IDs are skipped.
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
