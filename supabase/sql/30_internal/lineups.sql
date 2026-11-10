-- =====================================================================
-- Aufstellung
-- =====================================================================

-- Gültige Aufstellung: letzte gesetzte Aufstellung bis zu diesem Spieltag,
-- sonst die teuersten Fahrer des Kaders.
create or replace function effective_lineup(p_matchday uuid, p_manager uuid) returns setof text
language plpgsql stable security definer set search_path = public as $$
declare md matchdays; l leagues; v_src uuid;
begin
  select * into md from matchdays where id = p_matchday;
  select * into l from leagues where id = md.league_id;
  select lm.id into v_src from matchdays lm
   where lm.league_id = md.league_id and lm.starts_on <= md.starts_on
     and exists (select 1 from lineups x where x.matchday_id = lm.id and x.manager_id = p_manager)
   order by lm.starts_on desc limit 1;
  if v_src is not null then
    return query select x.rider_slug from lineups x where x.matchday_id = v_src and x.manager_id = p_manager;
    return;
  end if;
  return query select re.rider_slug from roster_entries re
    where re.manager_id = p_manager and re.acquired_on <= md.starts_on
      and (re.released_on is null or re.released_on > md.starts_on)
    order by re.price desc, re.id
    limit coalesce(md.lineup_size, l.lineup_size, l.roster_size);
end $$;

