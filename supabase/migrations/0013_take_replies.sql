-- 0013_take_replies: replies on the debate board, and editing your own message (Peter, 2026-11-27).
-- Peter: "I want the messaging section to be where you can reply and edit own message."
-- 1. Replies: any player can reply to a take (starter takes included). One level only, no replies to replies.
--    Same rules as takes: 2 to 280 characters, optional name, links and blocked words refused, rate-limited
--    by IP, the owner can hide them, and deleting a player deletes their replies.
-- 2. Editing: a player can edit their own reply (edit_reply) and their own take (post_take again, as before).
--    An edited take or reply shows "edited" (edited_at is set when the text actually changes).
-- 3. take_json gains 'edited' and 'replies' (how many visible replies the take has).
-- Player ids are never returned. Replies are deleted with their take.

-- ---------------------------------------------------------------- tables
alter table public.takes add column edited_at timestamptz;

create table public.take_replies (
  id         bigint generated always as identity primary key,
  take_id    bigint not null references public.takes(id) on delete cascade,
  player     text not null check (char_length(player) between 8 and 64),
  author     text check (author is null or char_length(author) between 1 and 24),
  body       text not null check (char_length(body) between 2 and 280),
  hidden     boolean not null default false,
  created_at timestamptz not null default now(),
  edited_at  timestamptz
);
create index take_replies_page_idx on public.take_replies (take_id, created_at, id);
create index take_replies_player_idx on public.take_replies (player);
alter table public.take_replies enable row level security;
revoke all on public.take_replies from anon, authenticated;

update public.config
   set value = value || jsonb_build_object('reply', jsonb_build_object('limit', 30, 'window', '1 hour'))
 where key = 'rate_limits';

-- ---------------------------------------------------------------- json
create or replace function public.take_json(t public.takes, p_player text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'author', t.author, 'pick', t.pick, 'reason', t.reason,
                            'seed', t.seed, 'mine', t.player is not null and t.player = p_player,
                            'hidden', t.hidden, 'at', t.created_at, 'edited', t.edited_at is not null,
                            'replies', (select count(*) from public.take_replies r where r.take_id = t.id and not r.hidden))
$$;

create function public.reply_json(r public.take_replies, p_player text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', r.id, 'take', r.take_id, 'author', r.author, 'body', r.body,
                            'mine', p_player is not null and r.player = p_player,
                            'hidden', r.hidden, 'at', r.created_at, 'edited', r.edited_at is not null)
$$;

-- ---------------------------------------------------------------- takes: mark edits
-- Same as 0011 except that replacing a take with different text sets edited_at.
create or replace function public.post_take(p_player text, p_slug text, p_pick text, p_reason text, p_author text default null)
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

  v_match := public.match_pick(p_slug, v_pick);
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
    set author = excluded.author, pick = excluded.pick, reason = excluded.reason, updated_at = now(),
        edited_at = case when (public.takes.author, public.takes.pick, public.takes.reason)
                              is distinct from (excluded.author, excluded.pick, excluded.reason)
                         then now() else public.takes.edited_at end
  returning * into v_take;

  return jsonb_build_object('take', public.take_json(v_take, p_player), 'voted', v_voted, 'pick', v_match);
end $$;

-- ---------------------------------------------------------------- replies
-- Posts a reply to a visible take. Returns the reply.
create function public.post_reply(p_player text, p_take bigint, p_body text, p_author text default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_body   text := public.clean_text(p_body);
  v_author text := public.clean_text(p_author);
  v_reply  public.take_replies;
begin
  if not public.enabled('takes_enabled') then
    raise exception 'disabled';
  end if;
  if char_length(coalesce(p_player, '')) not between 8 and 64
     or v_body is null or char_length(v_body) not between 2 and 280
     or (v_author is not null and char_length(v_author) > 24) then
    raise exception 'bad_input';
  end if;
  if not exists (select 1 from public.takes t join public.catalog c on c.slug = t.slug
                  where t.id = p_take and not t.hidden and c.active) then
    raise exception 'not_found';
  end if;
  if public.text_blocked(v_body) or public.text_blocked(v_author) then
    raise exception 'blocked';
  end if;
  perform public.enforce_rate('reply');

  insert into public.take_replies (take_id, player, author, body)
  values (p_take, p_player, v_author, v_body)
  returning * into v_reply;
  return public.reply_json(v_reply, p_player);
end $$;

-- Changes the text of the player's own reply. Returns the reply.
create function public.edit_reply(p_player text, p_id bigint, p_body text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_body  text := public.clean_text(p_body);
  v_reply public.take_replies;
begin
  if not public.enabled('takes_enabled') then
    raise exception 'disabled';
  end if;
  if char_length(coalesce(p_player, '')) not between 8 and 64
     or v_body is null or char_length(v_body) not between 2 and 280 then
    raise exception 'bad_input';
  end if;
  if public.text_blocked(v_body) then
    raise exception 'blocked';
  end if;
  perform public.enforce_rate('reply');

  update public.take_replies r
     set body = v_body, edited_at = case when r.body is distinct from v_body then now() else r.edited_at end
   where r.id = p_id and r.player = p_player
  returning * into v_reply;
  if v_reply.id is null then
    raise exception 'not_found';
  end if;
  return public.reply_json(v_reply, p_player);
end $$;

-- One page of a take's replies, oldest first (the order of the conversation).
-- Returns {replies, more, total}: total counts the visible replies; the asking player's own hidden
-- replies are included for them only. For the next page pass the last reply's at and id.
create function public.reply_page(p_take bigint, p_player text default null, p_limit integer default 5,
                                  p_after_at timestamptz default null, p_after_id bigint default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with lim as (select least(greatest(coalesce(p_limit, 5), 1), 20) as n),
  page as (
    select r.* from public.take_replies r
     where r.take_id = p_take
       and (not r.hidden or (p_player is not null and r.player = p_player))
       and exists (select 1 from public.takes t where t.id = p_take and not t.hidden)
       and (p_after_id is null or (r.created_at, r.id) > (p_after_at, p_after_id))
     order by r.created_at, r.id
     limit (select n + 1 from lim))
  select jsonb_build_object(
    'replies', coalesce((select jsonb_agg(public.reply_json(p, p_player) order by p.created_at, p.id)
                           from (select * from page order by created_at, id limit (select n from lim)) p), '[]'::jsonb),
    'more', (select count(*) from page) > (select n from lim),
    'total', (select count(*) from public.take_replies r where r.take_id = p_take and not r.hidden
                and exists (select 1 from public.takes t where t.id = p_take and not t.hidden)))
$$;

-- ---------------------------------------------------------------- owner
-- Owner: the newest 100 replies, hidden ones included, with the take they answer.
create function public.owner_replies(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  return coalesce((
    select jsonb_agg(public.reply_json(r, null) || jsonb_build_object('slug', t.slug, 'take_author', t.author, 'take_pick', t.pick)
                     order by r.created_at desc)
      from (select * from public.take_replies order by created_at desc limit 100) r
      join public.takes t on t.id = r.take_id), '[]'::jsonb);
end $$;

create function public.owner_hide_reply(p_token text, p_id bigint, p_hidden boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_owner(p_token);
  update public.take_replies set hidden = coalesce(p_hidden, true) where id = p_id;
  if not found then
    raise exception 'bad_input';
  end if;
  insert into public.ops_log (kind, detail) values ('reply_hidden', jsonb_build_object('id', p_id, 'hidden', p_hidden));
end $$;

-- Deleting a player also deletes their replies (and, with their takes, the replies under those takes).
create or replace function public.owner_delete_player(p_token text, p_player text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_votes integer; v_sugg integer; v_events integer; v_takes integer; v_replies integer;
begin
  perform public.require_owner(p_token);
  if char_length(coalesce(p_player, '')) not between 8 and 64 then
    raise exception 'bad_input';
  end if;
  delete from public.catalog_votes where player = p_player; get diagnostics v_votes = row_count;
  delete from public.suggestions where voter = p_player;    get diagnostics v_sugg = row_count;
  delete from public.events where player = p_player;        get diagnostics v_events = row_count;
  delete from public.take_replies where player = p_player;  get diagnostics v_replies = row_count;
  delete from public.takes where player = p_player;         get diagnostics v_takes = row_count;
  insert into public.ops_log (kind, detail)
    values ('player_deleted', jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events,
                                                 'takes', v_takes, 'replies', v_replies));
  return jsonb_build_object('votes', v_votes, 'suggestions', v_sugg, 'events', v_events, 'takes', v_takes, 'replies', v_replies);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.reply_json(public.take_replies, text),
  public.post_reply(text, bigint, text, text), public.edit_reply(text, bigint, text),
  public.reply_page(bigint, text, integer, timestamptz, bigint),
  public.owner_replies(text), public.owner_hide_reply(text, bigint, boolean)
from public, anon, authenticated;
grant execute on function public.post_reply(text, bigint, text, text), public.edit_reply(text, bigint, text),
  public.reply_page(bigint, text, integer, timestamptz, bigint),
  public.owner_replies(text), public.owner_hide_reply(text, bigint, boolean)
to anon, authenticated;
