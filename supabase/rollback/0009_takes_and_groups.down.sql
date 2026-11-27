-- Rollback for 0009_takes_and_groups.sql. Drops the takes board and the category groups.
-- track() and owner_delete_player() go back to their 0006 versions: re-run those two functions from
-- 0006_analytics.sql after this file.
drop function if exists public.owner_hide_take(text, bigint, boolean);
drop function if exists public.owner_takes(text);
drop function if exists public.get_takes(text, text);
drop function if exists public.post_take(text, text, text, text, text);
drop function if exists public.take_json(public.takes, text);
drop function if exists public.text_blocked(text);
drop function if exists public.clean_text(text);
drop table if exists public.takes;
delete from public.events where event in ('hint', 'give_up', 'take_post');
alter table public.events drop constraint events_event_check;
alter table public.events add constraint events_event_check check (event in ('visit', 'game_start', 'game_complete', 'pick_vote', 'share',
  'practice_start', 'suggest', 'vote_error', 'offline'));
delete from public.config where key = 'takes_enabled';
update public.config set value = value - 'take' where key = 'rate_limits';
create or replace function public.get_catalog() returns jsonb
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
alter table public.catalog drop column if exists grp, drop column if exists sub;
