-- Usage: replace :tables / :tag. Example used before 0002 on 2026-11-25:
create schema if not exists backup;
revoke all on schema backup from public, anon, authenticated;
-- create table backup.suggestions_20261125_0002 as select * from public.suggestions;
-- alter table backup.suggestions_20261125_0002 enable row level security;
