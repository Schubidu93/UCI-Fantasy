create or replace function _rname(p_slug text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from riders where pcs_slug = p_slug), p_slug);
$$;

