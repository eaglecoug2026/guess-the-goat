-- 0005_suggestions_private.sql  (HANDOFF §5, §6, §7 suggestions)
-- Suggestions become private: no public select. Adds ip_hash (+ reviewed_at for the §10 retention rule),
-- my_suggestions(player), owner_queue(token), and rewrites suggest with IP + player limits and the
-- suggestions_enabled kill switch.

drop policy "Anyone can read suggestions" on public.suggestions;
revoke all on public.suggestions from anon, authenticated;

alter table public.suggestions
  add column ip_hash text,
  add column reviewed_at timestamptz;

drop function public.suggest(text, text, text[]);

-- Codes: disabled, bad_input (player 8-64, name 2-60, <= 16 contenders of <= 40 chars),
-- duplicate (same name pending/added or already in the catalog), rate_limited (10/day per IP hash,
-- 10/day per player, or 500 pending).
create function public.suggest(p_player text, p_name text, p_opts text[]) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_name  text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
  v_opts  text[];
  v_rule  jsonb := public.cfg('rate_limits') -> 'suggest';
  v_id    uuid;
begin
  if not public.enabled('suggestions_enabled') then
    raise exception 'disabled';
  end if;
  if char_length(coalesce(p_player, '')) not between 8 and 64
     or char_length(v_name) not between 2 and 60
     or exists (select 1 from unnest(coalesce(p_opts, '{}')) x where char_length(btrim(x)) > 40) then
    raise exception 'bad_input';
  end if;
  select coalesce(array_agg(o order by ord), '{}') into v_opts from (
    select distinct on (lower(btrim(x))) btrim(x) as o, ord
      from unnest(coalesce(p_opts, '{}')) with ordinality as t(x, ord)
     where btrim(x) <> ''
     order by lower(btrim(x)), ord) d;
  if cardinality(v_opts) > 16 then
    raise exception 'bad_input';
  end if;
  if exists (select 1 from public.suggestions where lower(name) = lower(v_name) and status <> 'dismissed')
     or exists (select 1 from public.catalog where lower(name) = lower(v_name) and active) then
    raise exception 'duplicate';
  end if;
  if (select count(*) from public.suggestions
       where voter = p_player and created_at > now() - interval '1 day')
     >= coalesce((v_rule ->> 'per_player')::integer, 10)
     or (select count(*) from public.suggestions where status = 'pending') >= 500 then
    raise exception 'rate_limited';
  end if;
  perform public.enforce_rate('suggest');
  insert into public.suggestions (name, opts, voter, ip_hash)
    values (v_name, v_opts, p_player, public.request_ip_hash())
  returning id into v_id;
  return v_id;
end $$;

create function public.my_suggestions(p_player text) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if char_length(coalesce(p_player, '')) not between 8 and 64 then
    raise exception 'bad_input';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'opts', to_jsonb(s.opts),
                                        'status', s.status, 'created_at', s.created_at)
                     order by s.created_at desc)
      from public.suggestions s where s.voter = p_player), '[]'::jsonb);
end $$;

create function public.owner_queue(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'opts', to_jsonb(s.opts),
                                        'created_at', s.created_at)
                     order by s.created_at)
      from public.suggestions s where s.status = 'pending'), '[]'::jsonb);
end $$;

-- Same as 0004, plus reviewed_at.
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
    update public.suggestions set status = 'dismissed', reviewed_at = now() where id = p_id;
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
    update public.suggestions set status = 'added', reviewed_at = now() where id = p_id;
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
    update public.suggestions set status = 'dismissed', reviewed_at = now()
     where id = v_sid and status <> 'dismissed';
  end if;
end $$;

revoke all on function public.suggest(text, text, text[]), public.my_suggestions(text), public.owner_queue(text)
from public, anon, authenticated;
grant execute on function public.suggest(text, text, text[]), public.my_suggestions(text), public.owner_queue(text)
to anon, authenticated;
