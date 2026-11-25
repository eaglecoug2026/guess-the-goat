-- Rollback for 0006_analytics.sql. Apply rollbacks in reverse order (0006 -> 0002).
-- Restore events from backup.* afterwards only if the migration is being re-applied.
select cron.unschedule('goat-cleanup') where exists (select 1 from cron.job where jobname = 'goat-cleanup');
drop function if exists public.cleanup_retention();
drop function if exists public.owner_delete_player(text, text);
drop function if exists public.owner_stats(text);
drop function if exists public.track(jsonb);
drop schema if exists reports cascade;
drop table if exists public.events;
