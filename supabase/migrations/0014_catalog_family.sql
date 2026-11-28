-- 0014_catalog_family: a third menu level (Peter, 2026-11-27).
-- Peter's category list puts the player positions under one family inside a group:
--   Sports > NFL player > All, QB, RB, ...   Sports > NBA player > All, PG, SG, ...   Sports > MLB player > All, Pitcher, ...
-- catalog.fam is that family (null for a category that sits directly in its group). get_catalog returns it.
-- The NFL group itself moves into Sports; that is content (supabase/seed/catalog.sql), not this migration.

alter table public.catalog
  add column fam text check (fam is null or char_length(fam) between 1 and 30);

create or replace function public.get_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', c.slug, 'name', c.name, 'title', c.title, 'kind', c.kind, 'season', c.season,
        'source', c.source, 'opts', c.opts, 'clues', c.clues, 'grp', c.grp, 'fam', c.fam, 'sub', c.sub,
        'tier', public.tier_of((r.rk ->> 'total_votes')::integer))
      || r.rk
      order by c.kind, c.slug), '[]'::jsonb)
  from public.catalog c
  cross join lateral (select public.ranking_of(c.slug) as rk) r
  where c.active
$$;
