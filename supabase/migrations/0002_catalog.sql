-- 0002_catalog.sql  (HANDOFF §5)
-- config + secrets, catalog, catalog_votes, vote_counts (+ trigger), rate_limits + check_rate,
-- ops_log, get_catalog, cast_vote (slug-based). Migrates categories -> catalog and votes -> catalog_votes,
-- then drops the old tables.
-- Conventions (HANDOFF §5 "Function rules"): every function is SECURITY DEFINER with search_path = '';
-- only the public API is granted to anon/authenticated; everything else is revoked.
-- Supabase grants new public tables/functions to anon/authenticated by default, so every object
-- below revokes those grants explicitly.

-- ---------------------------------------------------------------- config / secrets
create table public.config (
  key    text primary key,
  value  jsonb not null,
  public boolean not null default false
);
alter table public.config enable row level security;
revoke all on public.config from anon, authenticated;
grant select on public.config to anon, authenticated;
create policy "Public config is readable" on public.config for select to anon, authenticated using (public);

insert into public.config (key, value, public) values
  ('k',                   '100'::jsonb,      true),
  ('launch_date',         'null'::jsonb,     true),   -- O-2: set by Peter; freezing is a no-op until set
  ('blend_tiers',         '[1, 500]'::jsonb, true),
  ('voting_enabled',      'true'::jsonb,     true),
  ('suggestions_enabled', 'true'::jsonb,     true),
  ('analytics_enabled',   'true'::jsonb,     true),
  ('repeat_window',       '30'::jsonb,       true),
  ('freeze_horizon_days', '3'::jsonb,        true),
  ('rate_limits', jsonb_build_object(
      'vote',        jsonb_build_object('limit', 120, 'window', '1 hour'),
      'suggest',     jsonb_build_object('limit', 10,  'window', '1 day', 'per_player', 10),
      'track',       jsonb_build_object('limit', 600, 'window', '1 hour'),
      'owner_login', jsonb_build_object('limit', 5,   'window', '15 minutes')), false);

create table public.secrets (
  key   text primary key,
  value text not null
);
alter table public.secrets enable row level security;
revoke all on public.secrets from anon, authenticated;
insert into public.secrets (key, value) values ('ip_salt', encode(extensions.gen_random_bytes(32), 'hex'));

-- ---------------------------------------------------------------- ops_log
create table public.ops_log (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  kind   text not null,
  detail jsonb not null default '{}'::jsonb
);
create index ops_log_at_idx on public.ops_log (at);
alter table public.ops_log enable row level security;
revoke all on public.ops_log from anon, authenticated;

-- ---------------------------------------------------------------- catalog
create table public.catalog (
  slug          text primary key check (slug ~ '^[a-z0-9-]{2,40}$'),
  name          text not null check (char_length(name) between 1 and 60),
  title         text not null check (char_length(title) between 1 and 120),
  kind          text not null check (kind in ('daily', 'vote')),
  season        text,
  opts          jsonb not null check (jsonb_typeof(opts) = 'array' and jsonb_array_length(opts) between 4 and 16),
  clues         jsonb not null default '{}'::jsonb check (jsonb_typeof(clues) = 'object'),
  active        boolean not null default true,
  needs_clues   boolean not null default false,
  source        text not null check (source in ('builtin', 'community')),
  suggestion_id uuid references public.suggestions(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index catalog_suggestion_idx on public.catalog (suggestion_id);
alter table public.catalog enable row level security;
revoke all on public.catalog from anon, authenticated;
grant select on public.catalog to anon, authenticated;
create policy "Active categories are readable" on public.catalog for select to anon, authenticated using (active);

create table public.catalog_votes (
  slug       text not null references public.catalog(slug),
  player     text not null check (char_length(player) between 8 and 64),
  pick       text not null check (char_length(pick) between 1 and 40),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (slug, player)
);
create index catalog_votes_player_idx on public.catalog_votes (player);
alter table public.catalog_votes enable row level security;
revoke all on public.catalog_votes from anon, authenticated;

create table public.vote_counts (
  slug text not null references public.catalog(slug),
  pick text not null,
  n    integer not null default 0 check (n >= 0),
  primary key (slug, pick)
);
alter table public.vote_counts enable row level security;
revoke all on public.vote_counts from anon, authenticated;
grant select on public.vote_counts to anon, authenticated;
create policy "Vote counts are readable" on public.vote_counts for select to anon, authenticated using (true);

create table public.rate_limits (
  bucket       text not null,
  ip_hash      text not null,
  window_start timestamptz not null,
  count        integer not null default 0,
  primary key (bucket, ip_hash, window_start)
);
create index rate_limits_window_idx on public.rate_limits (window_start);
alter table public.rate_limits enable row level security;
revoke all on public.rate_limits from anon, authenticated;

-- ---------------------------------------------------------------- triggers
create function public.touch_updated_at() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;
create trigger catalog_touch before update on public.catalog
  for each row execute function public.touch_updated_at();

create function public.catalog_votes_count() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    update public.vote_counts set n = n - 1 where slug = old.slug and pick = old.pick;
    delete from public.vote_counts where slug = old.slug and pick = old.pick and n <= 0;
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    insert into public.vote_counts as vc (slug, pick, n) values (new.slug, new.pick, 1)
    on conflict (slug, pick) do update set n = vc.n + 1;
  end if;
  return null;
end $$;
create trigger catalog_votes_count after insert or update of slug, pick or delete on public.catalog_votes
  for each row execute function public.catalog_votes_count();

-- ---------------------------------------------------------------- internal helpers (not public)
create function public.cfg(p_key text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select c.value from public.config c where c.key = p_key
$$;

-- A kill switch is on unless it is explicitly false.
create function public.enabled(p_key text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(public.cfg(p_key) is distinct from 'false'::jsonb, true)
$$;

-- First x-forwarded-for entry, stored only as sha256(ip_salt || ip). Missing IP -> 'ip:unknown'.
create function public.request_ip_hash() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_headers text := nullif(current_setting('request.headers', true), '');
  v_ip text;
  v_salt text;
begin
  if v_headers is not null then
    v_ip := nullif(btrim(split_part(coalesce(v_headers::json ->> 'x-forwarded-for', ''), ',', 1)), '');
  end if;
  if v_ip is null then
    return 'ip:unknown';
  end if;
  select s.value into v_salt from public.secrets s where s.key = 'ip_salt';
  return encode(sha256(convert_to(coalesce(v_salt, '') || v_ip, 'UTF8')), 'hex');
end $$;

-- Fixed-window counter. Raises rate_limited once the window's count passes p_limit.
create function public.check_rate(p_bucket text, p_ip_hash text, p_limit integer, p_window interval, p_n integer default 1)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_secs  double precision := extract(epoch from p_window);
  v_start timestamptz;
  v_count integer;
begin
  if v_secs is null or v_secs <= 0 or p_limit is null then
    raise exception 'bad_input';
  end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / v_secs) * v_secs);
  insert into public.rate_limits as r (bucket, ip_hash, window_start, count)
  values (p_bucket, coalesce(p_ip_hash, 'ip:unknown'), v_start, greatest(p_n, 1))
  on conflict (bucket, ip_hash, window_start) do update set count = r.count + excluded.count
  returning r.count into v_count;
  if v_count > p_limit then
    raise exception 'rate_limited';
  end if;
end $$;

-- Applies the limit named in config.rate_limits to the caller's IP hash.
create function public.enforce_rate(p_name text, p_n integer default 1) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_rule jsonb := public.cfg('rate_limits') -> p_name;
begin
  if v_rule is null then
    raise exception 'bad_input';
  end if;
  perform public.check_rate(p_name, public.request_ip_hash(), (v_rule ->> 'limit')::integer,
                            (v_rule ->> 'window')::interval, p_n);
end $$;

-- Blended ranking (HANDOFF §3): b = (v + k*e) / (V + k); ordered by b desc, e desc, name (code-point order).
-- V counts only votes for the category's current contenders.
create function public.ranking_of(p_slug text) returns jsonb
language sql stable security definer set search_path = '' as $$
  with c as (
    select c.opts from public.catalog c where c.slug = p_slug
  ), kk as (
    select greatest(coalesce((public.cfg('k') #>> '{}')::numeric, 100), 0.000001) as k
  ), o as (
    select e ->> 'name' as name, coalesce((e ->> 'est')::numeric, 0) as est
    from c, jsonb_array_elements(c.opts) as e
  ), v as (
    select o.name, o.est, coalesce(vc.n, 0) as votes
    from o left join public.vote_counts vc on vc.slug = p_slug and vc.pick = o.name
  ), t as (
    select coalesce(sum(v.votes), 0)::integer as total from v
  ), b as (
    select v.*, (v.votes + kk.k * v.est) / (t.total + kk.k) as bx from v, kk, t
  ), r as (
    select b.*, row_number() over (order by b.bx desc, b.est desc, b.name collate "C") as rank from b
  )
  select jsonb_build_object(
    'k', (select k from kk),
    'total_votes', (select total from t),
    'ranking', coalesce((select jsonb_agg(jsonb_build_object(
        'name', r.name, 'est', r.est, 'votes', r.votes, 'blended', round(r.bx, 6), 'rank', r.rank)
        order by r.rank) from r), '[]'::jsonb))
$$;

-- Disclosure tier by total real votes: 0 -> estimated, 1-499 -> blended, 500+ -> community.
create function public.tier_of(p_total integer) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when p_total < coalesce((public.cfg('blend_tiers') ->> 0)::integer, 1)   then 'estimated'
    when p_total < coalesce((public.cfg('blend_tiers') ->> 1)::integer, 500) then 'blended'
    else 'community' end
$$;

create function public.refresh_vote_counts() returns void
language sql security definer set search_path = '' as $$
  delete from public.vote_counts where true;
  insert into public.vote_counts (slug, pick, n)
    select v.slug, v.pick, count(*)::integer from public.catalog_votes v group by v.slug, v.pick;
$$;

-- ---------------------------------------------------------------- public API
create function public.get_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', c.slug, 'name', c.name, 'title', c.title, 'kind', c.kind, 'season', c.season,
        'source', c.source, 'opts', c.opts, 'clues', c.clues,
        'tier', public.tier_of((r.rk ->> 'total_votes')::integer))
      || r.rk
      order by c.kind, c.slug), '[]'::jsonb)
  from public.catalog c
  cross join lateral (select public.ranking_of(c.slug) as rk) r
  where c.active
$$;

drop function public.cast_vote(text, uuid, text);
create function public.cast_vote(p_player text, p_slug text, p_pick text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.enabled('voting_enabled') then
    raise exception 'disabled';
  end if;
  if char_length(coalesce(p_player, '')) not between 8 and 64 then
    raise exception 'bad_input';
  end if;
  if not exists (
    select 1 from public.catalog c
    where c.slug = p_slug and c.active
      and exists (select 1 from jsonb_array_elements(c.opts) e where e ->> 'name' = p_pick)
  ) then
    raise exception 'bad_pick';
  end if;
  perform public.enforce_rate('vote');
  insert into public.catalog_votes (slug, player, pick) values (p_slug, p_player, p_pick)
  on conflict (slug, player) do update
    set pick = excluded.pick, updated_at = now()
    where public.catalog_votes.pick is distinct from excluded.pick;
end $$;

-- ---------------------------------------------------------------- data migration
-- Community categories keep a stable slug derived from their old uuid.
insert into public.catalog (slug, name, title, kind, season, opts, clues, active, needs_clues, source, suggestion_id, created_at)
select 'community-' || substr(replace(c.id::text, '-', ''), 1, 8),
       c.name,
       'GOAT ' || lower(c.name),
       'vote', null,
       (select jsonb_agg(jsonb_build_object('name', o, 'est', 0) order by ord)
          from unnest(c.opts) with ordinality as t(o, ord)),
       '{}'::jsonb, true, false, 'community', c.suggestion_id, c.created_at
from public.categories c;

insert into public.catalog_votes (slug, player, pick, created_at, updated_at)
select 'community-' || substr(replace(v.category_id::text, '-', ''), 1, 8), v.voter, v.pick, v.updated_at, v.updated_at
from public.votes v;

drop table public.votes;
drop table public.categories;

-- ---------------------------------------------------------------- grants
revoke all on function
  public.touch_updated_at(), public.catalog_votes_count(), public.cfg(text), public.enabled(text),
  public.request_ip_hash(), public.check_rate(text, text, integer, interval, integer),
  public.enforce_rate(text, integer), public.ranking_of(text), public.tier_of(integer),
  public.refresh_vote_counts(), public.get_catalog(), public.cast_vote(text, text, text)
from public, anon, authenticated;

grant execute on function public.get_catalog(), public.cast_vote(text, text, text) to anon, authenticated;
