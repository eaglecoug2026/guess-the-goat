-- SQL tests for 0014_catalog_family.sql. One transaction, rolled back.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;

insert into public.catalog (slug, name, title, kind, opts, source, grp, fam, sub) values
 ('test-f1', 'Test F1', 'GOAT test F1', 'daily', '[{"name":"A","est":0.5},{"name":"B","est":0.3},{"name":"C","est":0.2},{"name":"D","est":0}]', 'builtin', 'Testing', 'Test family', 'All'),
 ('test-f2', 'Test F2', 'GOAT test F2', 'daily', '[{"name":"A","est":0.5},{"name":"B","est":0.3},{"name":"C","est":0.2},{"name":"D","est":0}]', 'builtin', 'Testing', null, 'Plain');

set local role anon;
select pg_temp.ok('get_catalog returns fam',
  (select e ->> 'fam' = 'Test family' and e ->> 'grp' = 'Testing' and e ->> 'sub' = 'All' from jsonb_array_elements(public.get_catalog()) e where e ->> 'slug' = 'test-f1'));
select pg_temp.ok('fam is null for a category directly in its group',
  (select e -> 'fam' = 'null'::jsonb from jsonb_array_elements(public.get_catalog()) e where e ->> 'slug' = 'test-f2'));
reset role;
select pg_temp.ok('fam longer than 30 characters is refused',
  pg_temp.err($q$update public.catalog set fam = repeat('x', 31) where slug = 'test-f1'$q$) like '%check%');
select pg_temp.ok('empty fam is refused', pg_temp.err($q$update public.catalog set fam = '' where slug = 'test-f1'$q$) like '%check%');

select test, ok, detail from _r order by at;
rollback;
