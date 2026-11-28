-- Undo 0014_catalog_family. Roll the client back first (it reads fam but works without it).
create or replace function public.get_catalog() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(
      jsonb_build_object(
        'slug', c.slug, 'name', c.name, 'title', c.title, 'kind', c.kind, 'season', c.season,
        'source', c.source, 'opts', c.opts, 'clues', c.clues, 'grp', c.grp, 'sub', c.sub,
        'tier', public.tier_of((r.rk ->> 'total_votes')::integer))
      || r.rk
      order by c.kind, c.slug), '[]'::jsonb)
  from public.catalog c
  cross join lateral (select public.ranking_of(c.slug) as rk) r
  where c.active
$$;
alter table public.catalog drop column if exists fam;
