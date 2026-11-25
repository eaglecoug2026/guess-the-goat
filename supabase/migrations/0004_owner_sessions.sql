-- 0004_owner_sessions.sql  (HANDOFF §5, §6.3, §7 owner panel)
-- owner_sessions + owner_login / owner_logout / owner_revoke_all and the token-checked owner functions.
-- Moves the existing passphrase hash from owner_secret into secrets.owner_pass_hash (value is copied,
-- never printed). Drops check_owner, review_suggestion, remove_category and owner_secret.

create table public.owner_sessions (
  token_hash text primary key,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
alter table public.owner_sessions enable row level security;
revoke all on public.owner_sessions from anon, authenticated;

-- Move the hash. Fails the whole migration if there is no hash to move.
do $$
begin
  if not exists (select 1 from public.owner_secret where id = 1) then
    raise exception 'owner_secret has no row; refusing to drop it';
  end if;
  insert into public.secrets (key, value)
    select 'owner_pass_hash', s.pass_hash from public.owner_secret s where s.id = 1
  on conflict (key) do update set value = excluded.value;
end $$;

drop function public.review_suggestion(text, uuid, text, text[]);
drop function public.remove_category(text, uuid);
drop function public.check_owner(text);
drop table public.owner_secret;

-- ---------------------------------------------------------------- session helpers (internal)
create function public.token_hash(p_token text) returns text
language sql immutable security definer set search_path = '' as $$
  select encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex')
$$;

create function public.require_owner(p_token text) returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if p_token is null or char_length(p_token) > 200 or not exists (
    select 1 from public.owner_sessions s
     where s.token_hash = public.token_hash(p_token)
       and s.revoked_at is null
       and s.expires_at > now()
  ) then
    raise exception 'not_owner';
  end if;
end $$;

-- ---------------------------------------------------------------- login / logout
-- Returns a 32-byte base64url token on success, null on a wrong passphrase. Rate-limited per IP hash
-- (config.rate_limits.owner_login, 5 per 15 minutes); failed attempts still count.
create function public.owner_login(p_pass text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_hash  text;
  v_token text;
begin
  perform public.enforce_rate('owner_login');
  select s.value into v_hash from public.secrets s where s.key = 'owner_pass_hash';
  if p_pass is null or char_length(p_pass) > 200 or v_hash is null
     or extensions.crypt(p_pass, v_hash) is distinct from v_hash then
    insert into public.ops_log (kind, detail)
      values ('owner_login_failed', jsonb_build_object('ip_hash', public.request_ip_hash()));
    return null;
  end if;
  v_token := translate(rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='), '+/', '-_');
  insert into public.owner_sessions (token_hash, expires_at)
    values (public.token_hash(v_token), now() + interval '12 hours');
  return v_token;
end $$;

create function public.owner_logout(p_token text) returns void
language sql security definer set search_path = '' as $$
  update public.owner_sessions set revoked_at = now()
   where token_hash = public.token_hash(p_token) and revoked_at is null
$$;

create function public.owner_revoke_all(p_token text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  update public.owner_sessions set revoked_at = now() where revoked_at is null;
  insert into public.ops_log (kind) values ('owner_revoke_all');
end $$;

-- ---------------------------------------------------------------- owner functions
-- Add (with editable contenders, 4-16, each <= 40 chars) or dismiss a pending suggestion.
-- Returns the new category slug for 'add', null for 'dismiss'.
create function public.owner_review_suggestion(p_token text, p_id uuid, p_action text, p_opts text[])
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

-- Removing a category deactivates it; categories are never deleted.
create function public.owner_remove_category(p_token text, p_slug text) returns void
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

create function public.owner_needs_clues(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'slug', c.slug, 'name', c.name,
             'top', public.ranking_of(c.slug) -> 'ranking' -> 0 ->> 'name') order by c.slug)
      from public.catalog c where c.active and c.needs_clues), '[]'::jsonb);
end $$;

-- The next 30 dates: owner override (if any) and the frozen category (if already frozen).
create function public.owner_schedule(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  return (
    select jsonb_agg(jsonb_build_object(
             'date', d::date, 'slug', s.slug, 'note', s.note, 'frozen_slug', p.slug) order by d)
      from generate_series(public.utc_today(), public.utc_today() + 29, interval '1 day') d
      left join public.schedule s on s.puzzle_date = d::date
      left join public.daily_puzzles p on p.puzzle_date = d::date);
end $$;

-- Set (or clear, with p_slug null) the override for one of the next 30 dates. Frozen dates can't change.
create function public.owner_set_schedule(p_token text, p_date date, p_slug text, p_note text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  if p_date is null or p_date < public.utc_today() or p_date > public.utc_today() + 29
     or exists (select 1 from public.daily_puzzles where puzzle_date = p_date)
     or char_length(coalesce(p_note, '')) > 200 then
    raise exception 'bad_input';
  end if;
  if p_slug is null then
    delete from public.schedule where puzzle_date = p_date;
    return;
  end if;
  if not exists (select 1 from public.catalog where slug = p_slug and active) then
    raise exception 'bad_input';
  end if;
  insert into public.schedule (puzzle_date, slug, note) values (p_date, p_slug, nullif(btrim(p_note), ''))
  on conflict (puzzle_date) do update set slug = excluded.slug, note = excluded.note;
end $$;

-- The only permitted change to a published puzzle.
create function public.owner_set_correction(p_token text, p_date date, p_note text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'bad_input';
  end if;
  update public.daily_puzzles set correction_note = nullif(btrim(p_note), '') where puzzle_date = p_date;
  if not found then
    raise exception 'bad_input';
  end if;
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function
  public.token_hash(text), public.require_owner(text), public.owner_login(text), public.owner_logout(text),
  public.owner_revoke_all(text), public.owner_review_suggestion(text, uuid, text, text[]),
  public.owner_remove_category(text, text), public.owner_needs_clues(text), public.owner_schedule(text),
  public.owner_set_schedule(text, date, text, text), public.owner_set_correction(text, date, text)
from public, anon, authenticated;

grant execute on function
  public.owner_login(text), public.owner_logout(text), public.owner_revoke_all(text),
  public.owner_review_suggestion(text, uuid, text, text[]), public.owner_remove_category(text, text),
  public.owner_needs_clues(text), public.owner_schedule(text),
  public.owner_set_schedule(text, date, text, text), public.owner_set_correction(text, date, text)
to anon, authenticated;
