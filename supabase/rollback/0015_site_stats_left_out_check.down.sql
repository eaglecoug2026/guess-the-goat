-- Rollback for 0015_site_stats_left_out_check.sql: the yes/no check goes away (visit.js then counts every
-- returning player's visit again, as after 0012). The left-out list itself is kept.
drop function if exists public.site_stats_is_left_out(text);
