-- =====================================================================
-- Spieltage
-- =====================================================================

-- Standard-Stichtag (Kader und Aufstellung fest):
--   nur Waiver:          Vortag des Spieltags, 20:00 Uhr
--   Waiver + frei:       Spieltagstart, 00:00 Uhr
create or replace function _default_deadline(p_league uuid, p_start date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when (select transfer_mode from leagues where id = p_league) = 'waiver_free'
              then p_start::timestamp at time zone 'Europe/Berlin'
              else (p_start - 1 + time '20:00')::timestamp at time zone 'Europe/Berlin' end;
$$;

-- Standard-Waiver-Auswertung im zweiteiligen Modus: Ende des 7. Tags vor Start (0:00 Uhr des 6. Tags vor Start).
-- Ist der vorige Spieltag kürzer als 14 Tage: nach der Hälfte seiner Dauer. Nie vor dem vorigen Stichtag.
create or replace function _default_waiver_deadline(p_league uuid, p_start date, p_except uuid default null) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare prev matchdays; v timestamptz; v_lock timestamptz := _default_deadline(p_league, p_start);
begin
  if (select transfer_mode from leagues where id = p_league) <> 'waiver_free' then return null; end if;
  select * into prev from matchdays where league_id = p_league and starts_on < p_start
     and id is distinct from p_except order by starts_on desc limit 1;
  if found and prev.ends_on - prev.starts_on + 1 < 14 then
    v := (prev.starts_on + (prev.ends_on - prev.starts_on + 1) / 2 + 1)::timestamp at time zone 'Europe/Berlin';
  else
    v := (p_start - 6)::timestamp at time zone 'Europe/Berlin';
  end if;
  if prev.id is not null and v <= prev.deadline then
    v := (((prev.deadline + (v_lock - prev.deadline) / 2) at time zone 'Europe/Berlin')::date + 1)
         ::timestamp at time zone 'Europe/Berlin';
    if v <= prev.deadline or v >= v_lock then v := prev.deadline + (v_lock - prev.deadline) / 2; end if;
  end if;
  return least(v, v_lock);
end $$;

