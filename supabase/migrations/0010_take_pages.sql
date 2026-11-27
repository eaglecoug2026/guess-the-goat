-- 0010_take_pages: the debate loads takes a page at a time (Peter, 2026-11-27).
-- A busy category could have thousands of takes, so the board shows 5 and a "Show more" button
-- instead of everything. Pages use a cursor (the last take shown), not an offset, so they stay fast
-- however deep a player reads and nobody is skipped when new takes arrive in between.
-- get_takes (0009) stays for pages already open in a browser; the client no longer calls it.

create index takes_page_idx on public.takes (slug, seed, created_at desc, id desc) where not hidden;

-- One page of a category's takes, player takes first, then starter takes, newest first.
-- Returns {takes, more, total, mine}:
--   takes  the page (1 to 20, default 5), never including the asking player's own take
--   more   true when there is another page after this one
--   total  every take in the category not hidden by the moderator
--   mine   the asking player's own take (hidden or not), on the first page only; null otherwise
-- For the next page pass the last take's seed, at and id as p_after_seed, p_after_at, p_after_id.
create function public.take_page(p_slug text, p_player text default null, p_limit integer default 5,
                                 p_after_seed boolean default null, p_after_at timestamptz default null,
                                 p_after_id bigint default null)
returns jsonb
language sql stable security definer set search_path = '' as $$
  with lim as (select least(greatest(coalesce(p_limit, 5), 1), 20) as n),
  page as (
    select t.* from public.takes t
     where t.slug = p_slug and not t.hidden
       and (p_player is null or t.player is null or t.player <> p_player)
       and (p_after_id is null
            or t.seed > coalesce(p_after_seed, false)
            or (t.seed = coalesce(p_after_seed, false) and (t.created_at, t.id) < (p_after_at, p_after_id)))
     order by t.seed, t.created_at desc, t.id desc
     limit (select n + 1 from lim))
  select jsonb_build_object(
    'takes', coalesce((select jsonb_agg(public.take_json(p, p_player) order by p.seed, p.created_at desc, p.id desc)
                         from (select * from page order by seed, created_at desc, id desc limit (select n from lim)) p),
                      '[]'::jsonb),
    'more', (select count(*) from page) > (select n from lim),
    'total', (select count(*) from public.takes t where t.slug = p_slug and not t.hidden),
    'mine', case when p_after_id is null and p_player is not null then
              (select public.take_json(t, p_player) from public.takes t where t.slug = p_slug and t.player = p_player) end)
$$;

revoke all on function public.take_page(text, text, integer, boolean, timestamptz, bigint) from public, anon, authenticated;
grant execute on function public.take_page(text, text, integer, boolean, timestamptz, bigint) to anon, authenticated;
