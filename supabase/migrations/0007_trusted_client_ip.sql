-- 0007_trusted_client_ip.sql  (DECISIONS D-25, amends HANDOFF §6.4)
-- The first x-forwarded-for entry is whatever the client sends, so every IP-hash rate limit could be
-- bypassed by rotating a fake header (verified live 2026-11-25). Supabase sits behind Cloudflare, which
-- sets cf-connecting-ip to the real client address and rejects requests that try to set it themselves
-- (403 / error 1000). The real address is also always the LAST x-forwarded-for entry.
-- Order: cf-connecting-ip -> last x-forwarded-for entry -> 'ip:unknown'. Still stored only as
-- sha256(ip_salt || ip). Grants are unchanged (internal helper, not callable by anon).

create or replace function public.request_ip_hash() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_headers json := nullif(current_setting('request.headers', true), '')::json;
  v_ip      text;
  v_xff     text[];
  v_salt    text;
begin
  if v_headers is not null then
    v_ip := nullif(btrim(v_headers ->> 'cf-connecting-ip'), '');
    if v_ip is null then
      v_xff := string_to_array(coalesce(v_headers ->> 'x-forwarded-for', ''), ',');
      if cardinality(v_xff) > 0 then
        v_ip := nullif(btrim(v_xff[cardinality(v_xff)]), '');
      end if;
    end if;
  end if;
  if v_ip is null then
    return 'ip:unknown';
  end if;
  select s.value into v_salt from public.secrets s where s.key = 'ip_salt';
  return encode(sha256(convert_to(coalesce(v_salt, '') || v_ip, 'UTF8')), 'hex');
end $$;
