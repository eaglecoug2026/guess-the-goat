-- 0001_goat_core.sql
-- RECORD ONLY. This is an export of migration "goat_core" (version 20261125114353),
-- which was applied to project mzlbnsibalthsycmvshm before this repo tracked migrations.
-- Do not re-apply it. Exported verbatim from supabase_migrations.schema_migrations.

create extension if not exists pgcrypto with schema extensions;

create table public.owner_secret (id int primary key default 1 check (id = 1), pass_hash text not null);
alter table public.owner_secret enable row level security;
revoke all on public.owner_secret from anon, authenticated;

create table public.suggestions (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 60),
  opts text[] not null default '{}' check (cardinality(opts) <= 16),
  voter text not null check (char_length(voter) between 8 and 64),
  status text not null default 'pending' check (status in ('pending','added','dismissed')),
  created_at timestamptz not null default now()
);
create index suggestions_voter_idx on public.suggestions (voter, created_at);
alter table public.suggestions enable row level security;
create policy "Anyone can read suggestions" on public.suggestions for select to anon, authenticated using (true);
revoke all on public.suggestions from anon, authenticated;
grant select (id, name, opts, status, created_at) on public.suggestions to anon, authenticated;

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

create or replace function public.check_owner(p_pass text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.owner_secret s where s.pass_hash = extensions.crypt(coalesce(p_pass,''), s.pass_hash));
$$;

create or replace function public.suggest(p_voter text, p_name text, p_opts text[]) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_name text := regexp_replace(btrim(coalesce(p_name,'')), '\s+', ' ', 'g');
        v_opts text[];
        v_id uuid;
begin
  if char_length(coalesce(p_voter,'')) not between 8 and 64 then raise exception 'bad_voter'; end if;
  if char_length(v_name) not between 2 and 60 then raise exception 'bad_name'; end if;
  select coalesce(array_agg(o order by ord), '{}') into v_opts from (
    select distinct on (lower(btrim(x))) left(btrim(x), 40) as o, ord
    from unnest(coalesce(p_opts,'{}')) with ordinality as t(x, ord)
    where btrim(x) <> '' order by lower(btrim(x)), ord) d;
  v_opts := v_opts[1:16];
  if (select count(*) from public.suggestions where voter = p_voter and created_at > now() - interval '1 day') >= 10 then raise exception 'too_many'; end if;
  if (select count(*) from public.suggestions where status = 'pending') >= 500 then raise exception 'queue_full'; end if;
  if exists (select 1 from public.suggestions where lower(name) = lower(v_name) and status <> 'dismissed') then raise exception 'duplicate'; end if;
  insert into public.suggestions (name, opts, voter) values (v_name, v_opts, p_voter) returning id into v_id;
  return v_id;
end $$;

create or replace function public.cast_vote(p_voter text, p_category uuid, p_pick text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if char_length(coalesce(p_voter,'')) not between 8 and 64 then raise exception 'bad_voter'; end if;
  if not exists (select 1 from public.categories c where c.id = p_category and p_pick = any(c.opts)) then raise exception 'bad_pick'; end if;
  insert into public.votes (category_id, voter, pick) values (p_category, p_voter, p_pick)
  on conflict (category_id, voter) do update set pick = excluded.pick, updated_at = now();
end $$;

create or replace function public.review_suggestion(p_pass text, p_id uuid, p_action text, p_opts text[]) returns void
language plpgsql security definer set search_path = '' as $$
declare v_s public.suggestions; v_opts text[];
begin
  if not public.check_owner(p_pass) then raise exception 'not_owner'; end if;
  select * into v_s from public.suggestions where id = p_id;
  if not found then raise exception 'not_found'; end if;
  if p_action = 'dismiss' then
    update public.suggestions set status = 'dismissed' where id = p_id;
  elsif p_action = 'add' then
    select coalesce(array_agg(o order by ord), '{}') into v_opts from (
      select distinct on (lower(btrim(x))) left(btrim(x), 40) as o, ord
      from unnest(coalesce(p_opts,'{}')) with ordinality as t(x, ord)
      where btrim(x) <> '' order by lower(btrim(x)), ord) d;
    v_opts := v_opts[1:16];
    if cardinality(v_opts) < 4 then raise exception 'need_four'; end if;
    insert into public.categories (name, opts, suggestion_id) values (v_s.name, v_opts, p_id);
    update public.suggestions set status = 'added' where id = p_id;
  else raise exception 'bad_action'; end if;
end $$;

create or replace function public.remove_category(p_pass text, p_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_sid uuid;
begin
  if not public.check_owner(p_pass) then raise exception 'not_owner'; end if;
  delete from public.categories where id = p_id returning suggestion_id into v_sid;
  if v_sid is not null then update public.suggestions set status = 'dismissed' where id = v_sid; end if;
end $$;

revoke execute on function public.check_owner(text), public.suggest(text,text,text[]), public.cast_vote(text,uuid,text), public.review_suggestion(text,uuid,text,text[]), public.remove_category(text,uuid) from public;
grant execute on function public.check_owner(text), public.suggest(text,text,text[]), public.cast_vote(text,uuid,text), public.review_suggestion(text,uuid,text,text[]), public.remove_category(text,uuid) to anon, authenticated;
