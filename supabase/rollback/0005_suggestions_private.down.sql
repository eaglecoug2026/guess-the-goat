-- Rollback for 0005_suggestions_private.sql: suggestions public again, old suggest(p_voter, ...),
-- owner_review_suggestion / owner_remove_category back to their 0004 bodies.
drop function if exists public.owner_queue(text);
drop function if exists public.my_suggestions(text);
drop function if exists public.suggest(text, text, text[]);

create or replace function public.owner_review_suggestion(p_token text, p_id uuid, p_action text, p_opts text[])
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_s    public.suggestions;
  v_opts text[];
  v_slug text;
begin
  perform public.require_owner(p_token);
  select * into v_s from public.suggestions where id = p_id;
  if not found or v_s.status <> 'pending' then
    raise exception 'bad_input';
  end if;
  if p_action = 'dismiss' then
    update public.suggestions set status = 'dismissed' where id = p_id;
    return null;
  elsif p_action = 'add' then
    if exists (select 1 from unnest(coalesce(p_opts, '{}')) x where char_length(btrim(x)) > 40) then
      raise exception 'bad_input';
    end if;
    select coalesce(array_agg(o order by ord), '{}') into v_opts from (
      select distinct on (lower(btrim(x))) btrim(x) as o, ord
        from unnest(coalesce(p_opts, '{}')) with ordinality as t(x, ord)
       where btrim(x) <> ''
       order by lower(btrim(x)), ord) d;
    if cardinality(v_opts) not between 4 and 16 then
      raise exception 'bad_input';
    end if;
    v_slug := 'community-' || substr(replace(p_id::text, '-', ''), 1, 8);
    insert into public.catalog (slug, name, title, kind, opts, clues, source, suggestion_id)
    values (v_slug, v_s.name, 'GOAT ' || lower(v_s.name), 'vote',
            (select jsonb_agg(jsonb_build_object('name', o, 'est', 0) order by ord)
               from unnest(v_opts) with ordinality as t(o, ord)),
            '{}'::jsonb, 'community', p_id)
    on conflict (slug) do nothing;
    if not found then
      raise exception 'duplicate';
    end if;
    update public.suggestions set status = 'added' where id = p_id;
    return v_slug;
  end if;
  raise exception 'bad_input';
end $$;

create or replace function public.owner_remove_category(p_token text, p_slug text) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_sid uuid;
begin
  perform public.require_owner(p_token);
  update public.catalog set active = false where slug = p_slug and active returning suggestion_id into v_sid;
  if not found then
    raise exception 'bad_input';
  end if;
  if v_sid is not null then
    update public.suggestions set status = 'dismissed' where id = v_sid and status <> 'dismissed';
  end if;
end $$;

alter table public.suggestions drop column if exists ip_hash, drop column if exists reviewed_at;

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
revoke all on function public.suggest(text, text, text[]) from public, anon, authenticated;
grant execute on function public.suggest(text, text, text[]) to anon, authenticated;

create policy "Anyone can read suggestions" on public.suggestions for select to anon, authenticated using (true);
grant select (id, name, opts, status, created_at) on public.suggestions to anon, authenticated;
