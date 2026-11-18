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
    return query select x.athlete_id from lineups x where x.matchday_id = v_src and x.manager_id = p_manager;
    return;
  end if;
  return query select re.athlete_id from roster_entries re
    where re.manager_id = p_manager and re.acquired_on <= md.starts_on
      and (re.released_on is null or re.released_on > md.starts_on)
    order by re.price desc, re.id
    limit coalesce(md.lineup_size, l.lineup_size, l.roster_size);
end $$;

create or replace function set_lineup(p_matchday uuid, p_riders text[]) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; l leagues; v_me uuid;
begin
  select * into md from matchdays where id = p_matchday;
  if not found then raise exception 'Spieltag nicht gefunden.'; end if;
  v_me := _require_member(md.league_id);
  select * into l from leagues where id = md.league_id;
  if now() >= md.deadline then raise exception 'Der Stichtag für diesen Spieltag ist vorbei.'; end if;
  if l.scoring_mode <> 'lineup' then raise exception 'Die Liga wertet den Gesamtkader.'; end if;
  if coalesce(array_length(p_riders, 1), 0) <> l.lineup_size then
    raise exception 'Bitte genau % Fahrer aufstellen.', l.lineup_size;
  end if;
  if exists (select 1 from unnest(p_riders) r where not exists (
      select 1 from roster_entries re where re.manager_id = v_me and re.athlete_id = r and re.released_on is null)) then
    raise exception 'Du kannst nur Fahrer aus deinem Kader aufstellen.';
  end if;
  delete from lineups where matchday_id = p_matchday and manager_id = v_me;
  insert into lineups (matchday_id, manager_id, athlete_id) select p_matchday, v_me, unnest(p_riders);
end $$;

-- Abgegebener Fahrer stand in Aufstellungen ab p_from: der neue rückt nach (sofern er nicht schon aufgestellt ist)
create or replace function _lineup_swap(p_league uuid, p_manager uuid, p_drop text, p_add text, p_from date) returns void
language sql security definer set search_path = public as $$
  update lineups x set athlete_id = p_add
    from matchdays m
   where m.id = x.matchday_id and m.league_id = p_league and m.starts_on >= p_from
     and x.manager_id = p_manager and x.athlete_id = p_drop and p_add is not null
     and not exists (select 1 from lineups y where y.matchday_id = x.matchday_id and y.manager_id = x.manager_id and y.athlete_id = p_add);
  delete from lineups x using matchdays m
   where m.id = x.matchday_id and m.league_id = p_league and m.starts_on >= p_from
     and x.manager_id = p_manager and x.athlete_id = p_drop;
$$;
