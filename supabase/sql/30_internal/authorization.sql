-- =====================================================================
-- Hilfsfunktionen
-- =====================================================================

create or replace function is_member(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from managers where league_id = p_league and user_id = auth.uid());
$$;

create or replace function is_admin(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from leagues where id = p_league and admin_user = auth.uid());
$$;

create or replace function my_manager(p_league uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from managers where league_id = p_league and user_id = auth.uid();
$$;

