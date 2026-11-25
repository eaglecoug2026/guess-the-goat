-- Rollback for 0004_owner_sessions.sql: owner_secret comes back with the same hash (copied from
-- secrets.owner_pass_hash, never printed); passphrase functions check_owner / review_suggestion /
-- remove_category are restored exactly as in 0001. Note: review_suggestion and remove_category reference
-- public.categories, which only exists again once 0002 is rolled back too.
create table public.owner_secret (id int primary key default 1 check (id = 1), pass_hash text not null);
alter table public.owner_secret enable row level security;
revoke all on public.owner_secret from anon, authenticated;
do $$
begin
  if not exists (select 1 from public.secrets where key = 'owner_pass_hash') then
    raise exception 'secrets.owner_pass_hash missing; refusing to roll back';
  end if;
  insert into public.owner_secret (id, pass_hash)
    select 1, s.value from public.secrets s where s.key = 'owner_pass_hash';
  delete from public.secrets where key = 'owner_pass_hash';
end $$;

drop function if exists public.owner_set_correction(text, date, text);
drop function if exists public.owner_set_schedule(text, date, text, text);
drop function if exists public.owner_schedule(text);
drop function if exists public.owner_needs_clues(text);
drop function if exists public.owner_remove_category(text, text);
drop function if exists public.owner_review_suggestion(text, uuid, text, text[]);
drop function if exists public.owner_revoke_all(text);
drop function if exists public.owner_logout(text);
drop function if exists public.owner_login(text);
drop function if exists public.require_owner(text);
drop function if exists public.token_hash(text);
drop table if exists public.owner_sessions;

create or replace function public.check_owner(p_pass text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.owner_secret s where s.pass_hash = extensions.crypt(coalesce(p_pass,''), s.pass_hash));
$$;

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

revoke execute on function public.check_owner(text), public.review_suggestion(text,uuid,text,text[]), public.remove_category(text,uuid) from public, anon, authenticated;
grant execute on function public.check_owner(text), public.review_suggestion(text,uuid,text,text[]), public.remove_category(text,uuid) to anon, authenticated;
