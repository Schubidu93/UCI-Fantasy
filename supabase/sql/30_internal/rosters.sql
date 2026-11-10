-- Freie Kaderplätze eines Managers
create or replace function _open_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries r where r.manager_id = m.id and r.released_on is null)::int
  from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Höchstgebot im Draft: Restbudget minus (offene Plätze − 1) × Mindestgebot
create or replace function _max_bid(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when _open_slots(m.id) <= 0 then 0 else m.budget_left - (_open_slots(m.id) - 1) end
  from managers m where m.id = p_manager;
$$;

-- Würde der Manager mit diesem Fahrer die Grenze pro Profiteam überschreiten?
create or replace function _team_limit_ok(p_manager uuid, p_rider text, p_without text default null) returns boolean
language sql stable security definer set search_path = public as $$
  select l.max_per_team is null
      or rd.team is null
      or (select count(*) from roster_entries re join riders x on x.pcs_slug = re.rider_slug
          where re.manager_id = m.id and re.released_on is null and x.team = rd.team
            and re.rider_slug is distinct from p_without) < l.max_per_team
  from managers m join leagues l on l.id = m.league_id, riders rd
  where m.id = p_manager and rd.pcs_slug = p_rider;
$$;

-- Ist ein Fahrer in der Liga frei? Abgegebene Fahrer sind gesperrt, wenn sie
-- seit p_locked_since abgegeben wurden (= bis zum nächsten Stichtag).
create or replace function _rider_free(p_league uuid, p_rider text, p_locked_since timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from riders r join leagues l on l.id = p_league
                 where r.pcs_slug = p_rider and r.gender = l.gender)
     and not exists (select 1 from roster_entries
                     where league_id = p_league and rider_slug = p_rider
                       and (released_on is null or released_at >= p_locked_since));
$$;

create or replace function _release(p_league uuid, p_manager uuid, p_rider text, p_on date) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update roster_entries set released_on = p_on, released_at = now()
   where league_id = p_league and manager_id = p_manager and rider_slug = p_rider and released_on is null;
  return found;
end $$;

