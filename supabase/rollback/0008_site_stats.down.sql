-- Rollback for 0008_site_stats.sql: removes the Site Stats feed and its token hash.
-- The ProctorPilot Site Stats page then shows "Couldn't get player counts" for The GOAT.
drop function if exists public.site_stats_daily(text, date, date);
delete from public.secrets where key = 'site_stats_token_sha256';
