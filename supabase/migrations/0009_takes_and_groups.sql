-- 0009_takes_and_groups.sql  (DECISIONS D-31, D-32)
-- 1. Category groups: catalog.grp (broad, e.g. "NFL") and catalog.sub (short, e.g. "QB"), returned by get_catalog.
-- 2. Takes: after a round, a player names their own GOAT (any text) and says why. Takes are public, one per
--    player per category (posting again replaces it). A take whose pick matches a contender (case-insensitive)
--    also counts as that player's vote. Starter takes (seed = true) are written by us and labeled in the game.
-- 3. New analytics events: hint, give_up, take_post.
-- Player ids are never returned. Blocked words live in secrets.blocked_words (comma-separated, not in the repo).

-- ---------------------------------------------------------------- groups
alter table public.catalog
  add column grp text check (grp is null or char_length(grp) between 1 and 30),
  add column sub text check (sub is null or char_length(sub) between 1 and 30);

create or replace function public.get_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', c.slug, 'name', c.name, 'title', c.title, 'kind', c.kind, 'season', c.season,
        'source', c.source, 'opts', c.opts, 'clues', c.clues, 'grp', c.grp, 'sub', c.sub,
        'tier', public.tier_of((r.rk ->> 'total_votes')::integer))
      || r.rk
      order by c.kind, c.slug), '[]'::jsonb)
  from public.catalog c
  cross join lateral (select public.ranking_of(c.slug) as rk) r
  where c.active
$$;

-- ---------------------------------------------------------------- takes
create table public.takes (
  id         bigint generated always as identity primary key,
  slug       text not null references public.catalog(slug) on delete cascade,
  player     text check (player is null or char_length(player) between 8 and 64),
  author     text check (author is null or char_length(author) between 1 and 24),
  pick       text not null check (char_length(pick) between 1 and 40),
  reason     text not null check (char_length(reason) between 2 and 280),
  seed       boolean not null default false,
  hidden     boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (seed or player is not null)
);
create unique index takes_slug_player_idx on public.takes (slug, player) where player is not null;
create index takes_slug_created_idx on public.takes (slug, created_at desc);
create index takes_player_idx on public.takes (player);
alter table public.takes enable row level security;
revoke all on public.takes from anon, authenticated;

insert into public.config (key, value, public) values ('takes_enabled', 'true'::jsonb, true)
on conflict (key) do nothing;
update public.config
   set value = value || jsonb_build_object('take', jsonb_build_object('limit', 20, 'window', '1 hour'))
 where key = 'rate_limits';

-- Trims and collapses whitespace.
create function public.clean_text(p text) returns text
language sql immutable set search_path = '' as $$
  select nullif(btrim(regexp_replace(coalesce(p, ''), '\s+', ' ', 'g')), '')
$$;

-- True when the text has a link or a blocked word (whole word, case-insensitive).
create function public.text_blocked(p text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare
  v_t    text := lower(coalesce(p, ''));
  v_list text;
  w      text;
begin
  if v_t ~ '(https?://|www\.|\m[a-z0-9-]+\.(com|net|org|io|ly|gg|co|me|xyz)\M)' then
    return true;
  end if;
  select s.value into v_list from public.secrets s where s.key = 'blocked_words';
  foreach w in array string_to_array(coalesce(v_list, ''), ',') loop
    w := btrim(lower(w));
    if w <> '' and v_t ~ ('\m' || regexp_replace(w, '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '\M') then
      return true;
    end if;
  end loop;
  return false;
end $$;

create function public.take_json(t public.takes, p_player text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'author', t.author, 'pick', t.pick, 'reason', t.reason,
                            'seed', t.seed, 'mine', t.player is not null and t.player = p_player,
                            'hidden', t.hidden, 'at', t.created_at)
$$;

-- Posts or replaces the player's take. Returns {take, voted, pick}: pick is the contender name when the
-- typed pick matched one (and then it also counts as the player's vote, if voting is on).
create function public.post_take(p_player text, p_slug text, p_pick text, p_reason text, p_author text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_pick   text := public.clean_text(p_pick);
  v_reason text := public.clean_text(p_reason);
  v_author text := public.clean_text(p_author);
  v_match  text;
  v_voted  boolean := false;
  v_take   public.takes;
begin
  if not public.enabled('takes_enabled') then
    raise exception 'disabled';
  end if;
  if char_length(coalesce(p_player, '')) not between 8 and 64
     or v_pick is null or char_length(v_pick) > 40
     or v_reason is null or char_length(v_reason) not between 2 and 280
     or (v_author is not null and char_length(v_author) > 24) then
    raise exception 'bad_input';
  end if;
  if not exists (select 1 from public.catalog c where c.slug = p_slug and c.active) then
    raise exception 'bad_input';
  end if;
  if public.text_blocked(v_pick) or public.text_blocked(v_reason) or public.text_blocked(v_author) then
    raise exception 'blocked';
  end if;
  perform public.enforce_rate('take');

  select e ->> 'name' into v_match
    from public.catalog c, jsonb_array_elements(c.opts) e
   where c.slug = p_slug and lower(e ->> 'name') = lower(v_pick)
   limit 1;
  if v_match is not null then
    v_pick := v_match;
    if public.enabled('voting_enabled') then
      insert into public.catalog_votes (slug, player, pick) values (p_slug, p_player, v_match)
      on conflict (slug, player) do update
        set pick = excluded.pick, updated_at = now()
        where public.catalog_votes.pick is distinct from excluded.pick;
      v_voted := true;
    end if;
  end if;

  insert into public.takes (slug, player, author, pick, reason)
  values (p_slug, p_player, v_author, v_pick, v_reason)
  on conflict (slug, player) where player is not null do update
    set author = excluded.author, pick = excluded.pick, reason = excluded.reason, updated_at = now()
  returning * into v_take;

  return jsonb_build_object('take', public.take_json(v_take, p_player), 'voted', v_voted, 'pick', v_match);
end $$;

-- The newest 60 visible takes for a category (the player's own take is included even if hidden), plus
-- how many visible takes there are in all.
create function public.get_takes(p_slug text, p_player text default null) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'takes', coalesce((
      select jsonb_agg(public.take_json(t, p_player) order by t.seed, t.created_at desc, t.id desc)
        from (select * from public.takes t
               where t.slug = p_slug and (not t.hidden or (p_player is not null and t.player = p_player))
               order by t.seed, t.created_at desc, t.id desc limit 60) t), '[]'::jsonb),
    'total', (select count(*) from public.takes t where t.slug = p_slug and not t.hidden))
$$;

-- Owner: the newest 100 player takes (not starter takes), hidden ones included.
create function public.owner_takes(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  return coalesce((
    select jsonb_agg(public.take_json(t, null) || jsonb_build_object('slug', t.slug) order by t.created_at desc)
      from (select * from public.takes where not seed order by created_at desc limit 100) t), '[]'::jsonb);
end $$;

create function public.owner_hide_take(p_token text, p_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  update public.takes set hidden = coalesce(p_hidden, true), updated_at = now() where id = p_id;
  if not found then
    raise exception 'bad_input';
  end if;
  insert into public.ops_log (kind, detail) values ('take_hidden', jsonb_build_object('id', p_id, 'hidden', p_hidden));
end $$;

-- Deleting a player also deletes their takes.
create or replace function public.owner_delete_player(p_token text, p_player text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_votes integer; v_sugg integer; v_events integer; v_takes integer;
begin
  perform public.require_owner(p_token);
  if char_length(coalesce(p_player, '')) not between 8 and 64 then
    raise exception 'bad_input';
  end if;
  delete from public.catalog_votes where player = p_player; get diagnostics v_votes = row_count;
  delete from public.suggestions where voter = p_player;    get diagnostics v_sugg = row_count;
  delete from public.events where player = p_player;        get diagnostics v_events = row_count;
  delete from public.takes where player = p_player;         get diagnostics v_takes = row_count;
  insert into public.ops_log (kind, detail)
    values ('player_deleted', jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events, 'takes', v_takes));
  return jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events, 'takes', v_takes);
end $$;

-- ---------------------------------------------------------------- analytics: three new events
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in ('visit', 'game_start', 'game_complete', 'pick_vote', 'share',
  'practice_start', 'suggest', 'vote_error', 'offline', 'hint', 'give_up', 'take_post'));
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

-- ---------------------------------------------------------------- grants
revoke all on function public.clean_text(text), public.text_blocked(text), public.take_json(public.takes, text),
  public.post_take(text, text, text, text, text), public.get_takes(text, text),
  public.owner_takes(text), public.owner_hide_take(text, bigint, boolean)
from public, anon, authenticated;
grant execute on function public.post_take(text, text, text, text, text), public.get_takes(text, text),
  public.owner_takes(text), public.owner_hide_take(text, bigint, boolean)
to anon, authenticated;
