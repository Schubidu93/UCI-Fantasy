create or replace function league_points(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, points numeric, overridden boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_points(p_league);
end $$;

create or replace function league_table(p_league uuid)
returns table (manager_id uuid, team_name text, total numeric, matchday_wins int, best_matchday numeric,
               spent int, "position" int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_table(p_league);
end $$;

create or replace function waiver_order(p_league uuid)
returns table (manager_id uuid, team_name text, waiver_pos int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _waiver_order(p_league);
end $$;

