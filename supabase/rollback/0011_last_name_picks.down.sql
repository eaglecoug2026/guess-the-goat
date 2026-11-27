-- Undo 0011_last_name_picks: post_take goes back to exact names only (the 0009 version), then match_pick goes.
-- Posts or replaces the player's take. Returns {take, voted, pick}: pick is the contender name when the
-- typed pick matched one (and then it also counts as the player's vote, if voting is on).
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

drop function if exists public.match_pick(text, text);
