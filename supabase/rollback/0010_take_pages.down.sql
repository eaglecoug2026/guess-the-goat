-- Undo 0010_take_pages. Roll the client back first: older pages call get_takes (0009), which stays.
drop function if exists public.take_page(text, text, integer, boolean, timestamptz, bigint);
drop index if exists public.takes_page_idx;
