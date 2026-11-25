-- Rollback for 0007_trusted_client_ip.sql: back to the 0002 body (first x-forwarded-for entry).
-- Note: this reopens the spoofing hole described in 0007.
create or replace function public.request_ip_hash() returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_headers text := nullif(current_setting('request.headers', true), '');
  v_ip text;
  v_salt text;
begin
  if v_headers is not null then
    v_ip := nullif(btrim(split_part(coalesce(v_headers::json ->> 'x-forwarded-for', ''), ',', 1)), '');
  end if;
  if v_ip is null then
    return 'ip:unknown';
  end if;
  select s.value into v_salt from public.secrets s where s.key = 'ip_salt';
  return encode(sha256(convert_to(coalesce(v_salt, '') || v_ip, 'UTF8')), 'hex');
end $$;
