-- SQL tests for 0007_trusted_client_ip.sql. One transaction, rolled back.
-- Headers mimic what Supabase passes through: cf-connecting-ip (set by Cloudflare) plus a client-controlled
-- x-forwarded-for prefix.
begin;
create temp table _r (at timestamptz default clock_timestamp(), test text, ok boolean, detail text) on commit drop;
grant all on _r to anon, authenticated;
create function pg_temp.ok(p_test text, p_ok boolean, p_detail text default null) returns void
  language sql as $$ insert into _r (test, ok, detail) values (p_test, coalesce(p_ok, false), p_detail) $$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin execute p_sql; return 'ok'; exception when others then return sqlerrm; end $$;
create function pg_temp.h(p_ip text) returns text language sql as $$
  select encode(sha256(convert_to((select value from public.secrets where key = 'ip_salt') || p_ip, 'UTF8')), 'hex') $$;
create function pg_temp.hash_with(p_headers text) returns text language plpgsql as $$
begin perform set_config('request.headers', p_headers, true); return public.request_ip_hash(); end $$;

-- ---------- which address is used
select pg_temp.ok('cf-connecting-ip wins over a spoofed x-forwarded-for',
  pg_temp.hash_with('{"cf-connecting-ip":"203.0.113.5","x-forwarded-for":"198.51.100.9, 203.0.113.5"}') = pg_temp.h('203.0.113.5'));
select pg_temp.ok('spoofed first x-forwarded-for entry is ignored',
  pg_temp.hash_with('{"cf-connecting-ip":"203.0.113.5","x-forwarded-for":"198.51.100.9, 203.0.113.5"}') <> pg_temp.h('198.51.100.9'));
select pg_temp.ok('without cf-connecting-ip: last x-forwarded-for entry',
  pg_temp.hash_with('{"x-forwarded-for":"198.51.100.9, 198.51.100.10, 203.0.113.6"}') = pg_temp.h('203.0.113.6'));
select pg_temp.ok('single x-forwarded-for entry still works', pg_temp.hash_with('{"x-forwarded-for":"203.0.113.7"}') = pg_temp.h('203.0.113.7'));
select pg_temp.ok('blank cf-connecting-ip falls back to x-forwarded-for',
  pg_temp.hash_with('{"cf-connecting-ip":" ","x-forwarded-for":"203.0.113.8"}') = pg_temp.h('203.0.113.8'));
select pg_temp.ok('no address -> ip:unknown', pg_temp.hash_with('{"user-agent":"x"}') = 'ip:unknown' and pg_temp.hash_with('') = 'ip:unknown');
select pg_temp.ok('stored value is a 64-char hash, never the address', pg_temp.hash_with('{"cf-connecting-ip":"203.0.113.5"}') ~ '^[0-9a-f]{64}$');

-- ---------- the bypass is closed: rotating x-forwarded-for no longer resets the vote limit
update public.catalog set active = false where active;
insert into public.catalog (slug, name, title, kind, opts, source) values
 ('test-ip', 'Test IP', 'GOAT test ip', 'vote', '[{"name":"W","est":0},{"name":"X","est":0},{"name":"Y","est":0},{"name":"Z","est":0}]', 'builtin');
set local role anon;
do $$
declare i integer; bad integer := 0;
begin
  for i in 1..120 loop
    perform set_config('request.headers', format('{"cf-connecting-ip":"203.0.113.50","x-forwarded-for":"198.51.%s.%s, 203.0.113.50"}', i / 250, i % 250), true);
    if pg_temp.err(format($q$select public.cast_vote('ip-player-%s','test-ip','W')$q$, lpad(i::text, 4, '0'))) <> 'ok' then bad := bad + 1; end if;
  end loop;
  perform pg_temp.ok('120 votes from one real IP (fake headers rotating) succeed', bad = 0, format('%s failed', bad));
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.50","x-forwarded-for":"192.0.2.250, 203.0.113.50"}', true);
  perform pg_temp.ok('121st vote with yet another fake x-forwarded-for -> rate_limited',
    pg_temp.err($q$select public.cast_vote('ip-player-0121','test-ip','W')$q$) = 'rate_limited');
  -- owner login brute force: 5 attempts, then blocked regardless of the fake header
  for i in 1..5 loop
    perform set_config('request.headers', format('{"cf-connecting-ip":"203.0.113.60","x-forwarded-for":"198.18.9.%s, 203.0.113.60"}', i), true);
    perform public.owner_login('wrong-pass-' || i);
  end loop;
  perform set_config('request.headers', '{"cf-connecting-ip":"203.0.113.60","x-forwarded-for":"198.18.9.99, 203.0.113.60"}', true);
  perform pg_temp.ok('6th owner login with a new fake x-forwarded-for -> rate_limited',
    pg_temp.err($q$select public.owner_login('wrong-pass-6')$q$) = 'rate_limited');
  perform pg_temp.ok('anon cannot call request_ip_hash', pg_temp.err('select public.request_ip_hash()') like 'permission denied%');
end $$;
reset role;

select test, ok, detail from _r order by at;
rollback;
