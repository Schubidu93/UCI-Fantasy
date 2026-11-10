create or replace function _is_service() returns boolean
language sql stable as $$
  select coalesce(auth.role(), '') = 'service_role' or session_user in ('postgres', 'supabase_admin');
$$;

create or replace function _require_member(p_league uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  v := my_manager(p_league);
  if v is null then raise exception 'Du bist kein Mitglied dieser Liga.'; end if;
  return v;
end $$;

create or replace function _require_admin(p_league uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(p_league) then raise exception 'Nur der Liga-Admin darf das.'; end if;
end $$;

