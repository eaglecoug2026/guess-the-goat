-- 0003_daily.sql  (HANDOFF §4, §5)
-- daily_puzzles (immutable snapshots), schedule, freeze_puzzle(date), freeze_upcoming(), get_daily(date),
-- and the pg_cron freeze job (00:05 UTC daily, freezes through UTC date + freeze_horizon_days).

create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------- tables
create table public.daily_puzzles (
  puzzle_date     date primary key,
  puzzle_no       integer not null unique check (puzzle_no >= 1),
  slug            text not null references public.catalog(slug),
  name            text not null,
  title           text not null,
  ranking         jsonb not null check (jsonb_typeof(ranking) = 'array'),
  answer          text not null,
  clues           jsonb not null check (jsonb_typeof(clues) = 'array' and jsonb_array_length(clues) = 4),
  k               numeric not null,
  total_votes     integer not null,
  tier            text not null check (tier in ('estimated', 'blended', 'community')),
  frozen_at       timestamptz not null default now(),
  correction_note text check (char_length(correction_note) <= 500)
);
create index daily_puzzles_slug_idx on public.daily_puzzles (slug);
alter table public.daily_puzzles enable row level security;
revoke all on public.daily_puzzles from anon, authenticated;
grant select on public.daily_puzzles to anon, authenticated;
-- Readable window: dates up to UTC date + 1 (covers UTC+14). Frozen puzzles further ahead stay hidden.
create policy "Published puzzles are readable" on public.daily_puzzles for select to anon, authenticated
  using (puzzle_date <= (now() at time zone 'utc')::date + 1);

-- A published puzzle never changes. Only correction_note may be updated (the owner does it via
-- owner_set_correction; anon has no table write grants at all).
create function public.daily_puzzles_immutable() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' or tg_op = 'TRUNCATE' then
    raise exception 'immutable';
  end if;
  if (to_jsonb(new) - 'correction_note') is distinct from (to_jsonb(old) - 'correction_note') then
    raise exception 'immutable';
  end if;
  return new;
end $$;
create trigger daily_puzzles_immutable before update or delete on public.daily_puzzles
  for each row execute function public.daily_puzzles_immutable();
create trigger daily_puzzles_no_truncate before truncate on public.daily_puzzles
  for each statement execute function public.daily_puzzles_immutable();

create table public.schedule (
  puzzle_date date primary key,
  slug        text not null references public.catalog(slug),
  note        text check (char_length(note) <= 200),
  created_at  timestamptz not null default now()
);
create index schedule_slug_idx on public.schedule (slug);
alter table public.schedule enable row level security;
revoke all on public.schedule from anon, authenticated;

-- ---------------------------------------------------------------- helpers
-- True when the category's current blended #1 has a full clue set (4 clues).
create function public.top_has_clues(p_slug text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select jsonb_typeof(c.clues -> (public.ranking_of(c.slug) -> 'ranking' -> 0 ->> 'name')) = 'array'
       and jsonb_array_length(c.clues -> (public.ranking_of(c.slug) -> 'ranking' -> 0 ->> 'name')) = 4
    from public.catalog c where c.slug = p_slug), false)
$$;

create function public.utc_today() returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone 'utc')::date
$$;

-- ---------------------------------------------------------------- freeze_puzzle
-- Freezes the puzzle for p_date (idempotent) and returns its snapshot, or null when the date is before
-- launch_date / launch_date is unset / nothing is eligible. Selection order (HANDOFF §4):
--   1. an owner schedule row, if the category is active and its blended #1 has clues
--   2. active daily categories with no season and a clued #1, not used in the last repeat_window puzzles,
--      least recently used first, ties by slug
--   3. categories whose #1 lacks clues get needs_clues = true (and the flag clears once fixed)
--   4. nothing eligible -> least recently used clued daily category, logged as pool_exhausted
create function public.freeze_puzzle(p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_launch date := (public.cfg('launch_date') #>> '{}')::date;
  v_window integer := coalesce((public.cfg('repeat_window') #>> '{}')::integer, 30);
  v_no     integer;
  v_slug   text;
  v_cat    public.catalog;
  v_rank   jsonb;
  v_answer text;
  v_row    public.daily_puzzles;
begin
  if p_date is null then
    raise exception 'bad_input';
  end if;
  select * into v_row from public.daily_puzzles where puzzle_date = p_date;
  if found then
    return to_jsonb(v_row);
  end if;
  if v_launch is null or p_date < v_launch then
    return null;
  end if;

  -- One freezer per date at a time (cron vs. lazy get_daily).
  perform pg_advisory_xact_lock(hashtext('goat_freeze'), p_date - date '2000-01-01');
  select * into v_row from public.daily_puzzles where puzzle_date = p_date;
  if found then
    return to_jsonb(v_row);
  end if;

  v_no := (p_date - v_launch) + 1;

  -- Keep needs_clues current for the daily pool.
  update public.catalog c
     set needs_clues = not public.top_has_clues(c.slug)
   where c.active and c.kind = 'daily'
     and c.needs_clues is distinct from (not public.top_has_clues(c.slug));

  -- 1. Owner schedule override.
  select s.slug into v_slug from public.schedule s where s.puzzle_date = p_date;
  if v_slug is not null then
    if not exists (select 1 from public.catalog c where c.slug = v_slug and c.active) then
      insert into public.ops_log (kind, detail)
        values ('schedule_skipped', jsonb_build_object('date', p_date, 'slug', v_slug, 'reason', 'inactive'));
      v_slug := null;
    elsif not public.top_has_clues(v_slug) then
      update public.catalog set needs_clues = true where slug = v_slug;
      insert into public.ops_log (kind, detail)
        values ('schedule_skipped', jsonb_build_object('date', p_date, 'slug', v_slug, 'reason', 'needs_clues'));
      v_slug := null;
    end if;
  end if;

  -- 2. Regular pool.
  if v_slug is null then
    select c.slug into v_slug
      from public.catalog c
      left join lateral (select max(d.puzzle_date) as last_used from public.daily_puzzles d where d.slug = c.slug) u on true
     where c.active and c.kind = 'daily' and c.season is null and not c.needs_clues
       and not exists (select 1 from public.daily_puzzles d
                        where d.slug = c.slug and d.puzzle_no between v_no - v_window and v_no - 1)
     order by u.last_used nulls first, c.slug
     limit 1;
  end if;

  -- 4. Pool exhausted: reuse the least recently used clued category.
  if v_slug is null then
    select c.slug into v_slug
      from public.catalog c
      left join lateral (select max(d.puzzle_date) as last_used from public.daily_puzzles d where d.slug = c.slug) u on true
     where c.active and c.kind = 'daily' and c.season is null and not c.needs_clues
     order by u.last_used nulls first, c.slug
     limit 1;
    if v_slug is not null then
      insert into public.ops_log (kind, detail)
        values ('pool_exhausted', jsonb_build_object('date', p_date, 'slug', v_slug));
    end if;
  end if;

  if v_slug is null then
    insert into public.ops_log (kind, detail)
      values ('freeze_failed', jsonb_build_object('date', p_date, 'reason', 'no_eligible_category'));
    return null;
  end if;

  select * into v_cat from public.catalog where slug = v_slug;
  v_rank   := public.ranking_of(v_slug);
  v_answer := v_rank -> 'ranking' -> 0 ->> 'name';

  insert into public.daily_puzzles
    (puzzle_date, puzzle_no, slug, name, title, ranking, answer, clues, k, total_votes, tier)
  values
    (p_date, v_no, v_slug, v_cat.name, v_cat.title, v_rank -> 'ranking', v_answer, v_cat.clues -> v_answer,
     (v_rank ->> 'k')::numeric, (v_rank ->> 'total_votes')::integer,
     public.tier_of((v_rank ->> 'total_votes')::integer))
  on conflict do nothing
  returning * into v_row;

  if v_row.puzzle_date is null then
    insert into public.ops_log (kind, detail)
      values ('freeze_failed', jsonb_build_object('date', p_date, 'reason', 'conflict', 'puzzle_no', v_no));
    select * into v_row from public.daily_puzzles where puzzle_date = p_date;
    return case when v_row.puzzle_date is null then null else to_jsonb(v_row) end;
  end if;

  insert into public.ops_log (kind, detail)
    values ('frozen', jsonb_build_object('date', p_date, 'puzzle_no', v_no, 'slug', v_slug));
  return to_jsonb(v_row);
end $$;

-- Cron entry point: freezes every missing date from max(launch_date, today - 1) through today + horizon.
-- p_today is a parameter only so SQL tests can mock the clock.
create function public.freeze_upcoming(p_today date default null) returns integer
language plpgsql security definer set search_path = '' as $$
declare
  v_today   date := coalesce(p_today, public.utc_today());
  v_launch  date := (public.cfg('launch_date') #>> '{}')::date;
  v_horizon integer := coalesce((public.cfg('freeze_horizon_days') #>> '{}')::integer, 3);
  v_d       date;
  v_n       integer := 0;
begin
  if v_launch is null then
    return 0;
  end if;
  v_d := greatest(v_launch, v_today - 1);
  while v_d <= v_today + v_horizon loop
    if not exists (select 1 from public.daily_puzzles where puzzle_date = v_d) then
      if public.freeze_puzzle(v_d) is not null then
        v_n := v_n + 1;
      end if;
    end if;
    v_d := v_d + 1;
  end loop;
  return v_n;
end $$;

-- ---------------------------------------------------------------- get_daily (public)
-- Returns the frozen snapshot for the player's local date. Dates past UTC date + 1 return null.
-- Lazy safety net: a missing date in the playable window (UTC date - 1 .. UTC date + 1) is frozen now
-- and logged as late_freeze. Call with POST (it may write).
create function public.get_daily(p_date date) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_today date := public.utc_today();
  v_row   jsonb;
begin
  if p_date is null then
    raise exception 'bad_input';
  end if;
  if p_date > v_today + 1 then
    return null;
  end if;
  select to_jsonb(d) into v_row from public.daily_puzzles d where d.puzzle_date = p_date;
  if v_row is not null then
    return v_row;
  end if;
  if p_date < v_today - 1 then
    return null;
  end if;
  v_row := public.freeze_puzzle(p_date);
  if v_row is not null then
    insert into public.ops_log (kind, detail) values ('late_freeze', jsonb_build_object('date', p_date));
  end if;
  return v_row;
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function
  public.daily_puzzles_immutable(), public.top_has_clues(text), public.utc_today(),
  public.freeze_puzzle(date), public.freeze_upcoming(date), public.get_daily(date)
from public, anon, authenticated;
grant execute on function public.get_daily(date) to anon, authenticated;

-- ---------------------------------------------------------------- cron
select cron.schedule('goat-freeze', '5 0 * * *', $cron$select public.freeze_upcoming()$cron$);
