-- Undo 0013_take_replies. Roll the client back first (older pages don't call the reply functions).
-- Replies are lost; restore them from backup.take_replies_<date>_0013 if one was taken.
drop function if exists public.owner_hide_reply(text, bigint, boolean);
drop function if exists public.owner_replies(text);
drop function if exists public.reply_page(bigint, text, integer, timestamptz, bigint);
drop function if exists public.edit_reply(text, bigint, text);
drop function if exists public.post_reply(text, bigint, text, text);
drop function if exists public.reply_json(public.take_replies, text);

-- take_json as in 0009
create or replace function public.take_json(t public.takes, p_player text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'author', t.author, 'pick', t.pick, 'reason', t.reason,
                            'seed', t.seed, 'mine', t.player is not null and t.player = p_player,
                            'hidden', t.hidden, 'at', t.created_at)
$$;

-- post_take as in 0011
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
    set author = excluded.author, pick = excluded.pick, reason = excluded.reason, updated_at = now()
  returning * into v_take;

  return jsonb_build_object('take', public.take_json(v_take, p_player), 'voted', v_voted, 'pick', v_match);
end $$;

-- owner_delete_player as in 0009
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

drop table if exists public.take_replies;
alter table public.takes drop column if exists edited_at;
update public.config set value = value - 'reply' where key = 'rate_limits';
