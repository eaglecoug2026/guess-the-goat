-- Rollback for 0003_daily.sql. Published puzzles are dropped with the table: take the backup first
-- (backup.daily_puzzles_<yyyymmdd>). The pg_cron extension itself is left installed.
select cron.unschedule('goat-freeze') where exists (select 1 from cron.job where jobname = 'goat-freeze');
drop function if exists public.get_daily(date);
drop function if exists public.freeze_upcoming(date);
drop function if exists public.freeze_puzzle(date);
drop table if exists public.schedule;
drop table if exists public.daily_puzzles;
drop function if exists public.daily_puzzles_immutable();
drop function if exists public.utc_today();
drop function if exists public.top_has_clues(text);
