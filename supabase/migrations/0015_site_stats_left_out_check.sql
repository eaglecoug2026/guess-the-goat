-- 0015_site_stats_left_out_check.sql  (DECISIONS D-38)
-- The left-out list also stops visit counts. The leave-me-out link only reaches the browser it opens in, and a
-- home-screen icon keeps its own storage apart from Safari, so the owner's icon kept counting. Now visit.js asks
-- site_stats_is_left_out(player ID) once a day before it counts a returning player's visit; after a yes it sends
-- no more visits from that browser. The answer is only yes or no for the ID asked about (player IDs are random,
-- so nobody can look up anyone else's), and nothing is stored. No table changes.

create function public.site_stats_is_left_out(p_player text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.site_stats_left_out l where l.player = p_player);
$$;

revoke all on function public.site_stats_is_left_out(text) from public, anon, authenticated;
grant execute on function public.site_stats_is_left_out(text) to anon;
