-- Rollback for 0002_catalog.sql: recreates categories / votes exactly as in 0001, copies community
-- categories and their votes back (new uuids), restores the old cast_vote, drops the new objects.
-- Builtin catalog rows have no place in the old schema and are dropped (they are re-seeded from
-- content/categories.json).
do $$
begin
  if exists (select 1 from public.secrets where key = 'owner_pass_hash') then
    raise exception 'roll back 0004 first (secrets still holds owner_pass_hash)';
  end if;
end $$;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 60),
  opts text[] not null check (cardinality(opts) between 4 and 16),
  suggestion_id uuid references public.suggestions(id) on delete set null,
  created_at timestamptz not null default now()
);
create index categories_suggestion_idx on public.categories (suggestion_id);
alter table public.categories enable row level security;
create policy "Anyone can read categories" on public.categories for select to anon, authenticated using (true);
revoke all on public.categories from anon, authenticated;
grant select on public.categories to anon, authenticated;

create table public.votes (
  category_id uuid not null references public.categories(id) on delete cascade,
  voter text not null check (char_length(voter) between 8 and 64),
  pick text not null,
  updated_at timestamptz not null default now(),
  primary key (category_id, voter)
);
alter table public.votes enable row level security;
create policy "Anyone can read vote picks" on public.votes for select to anon, authenticated using (true);
revoke all on public.votes from anon, authenticated;
grant select (category_id, pick) on public.votes to anon, authenticated;

create temp table _slug_map on commit drop as
  select c.slug, gen_random_uuid() as id from public.catalog c where c.source = 'community' and c.active;
insert into public.categories (id, name, opts, suggestion_id, created_at)
  select m.id, c.name,
         (select array_agg(e ->> 'name' order by ord) from jsonb_array_elements(c.opts) with ordinality as t(e, ord)),
         c.suggestion_id, c.created_at
    from public.catalog c join _slug_map m using (slug);
insert into public.votes (category_id, voter, pick, updated_at)
  select m.id, v.player, v.pick, v.updated_at from public.catalog_votes v join _slug_map m using (slug);

drop function if exists public.get_catalog();
drop function if exists public.cast_vote(text, text, text);
drop function if exists public.refresh_vote_counts();
drop function if exists public.tier_of(integer);
drop function if exists public.ranking_of(text);
drop function if exists public.enforce_rate(text, integer);
drop function if exists public.check_rate(text, text, integer, interval, integer);
drop function if exists public.request_ip_hash();
drop table if exists public.vote_counts;
drop table if exists public.catalog_votes;
drop table if exists public.catalog;
drop function if exists public.catalog_votes_count();
drop function if exists public.touch_updated_at();
drop function if exists public.enabled(text);
drop function if exists public.cfg(text);
drop table if exists public.rate_limits;
drop table if exists public.ops_log;
drop table if exists public.secrets;
drop table if exists public.config;

create or replace function public.cast_vote(p_voter text, p_category uuid, p_pick text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if char_length(coalesce(p_voter,'')) not between 8 and 64 then raise exception 'bad_voter'; end if;
  if not exists (select 1 from public.categories c where c.id = p_category and p_pick = any(c.opts)) then raise exception 'bad_pick'; end if;
  insert into public.votes (category_id, voter, pick) values (p_category, p_voter, p_pick)
  on conflict (category_id, voter) do update set pick = excluded.pick, updated_at = now();
end $$;
revoke execute on function public.cast_vote(text, uuid, text) from public, anon, authenticated;
grant execute on function public.cast_vote(text, uuid, text) to anon, authenticated;
