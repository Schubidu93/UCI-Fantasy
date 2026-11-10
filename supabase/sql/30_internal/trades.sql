-- =====================================================================
-- Tausch zwischen Managern
-- =====================================================================

-- Freie Kaderplätze eines Managers
create or replace function _open_roster_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries re where re.manager_id = m.id and re.released_on is null)::int
    from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Prüft Fahrer, die ein Manager im Tausch zusätzlich entlässt: im Kader, nicht Teil des Tauschs,
-- nicht schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen
create or replace function _check_trade_drops(p_manager uuid, p_drop text[], p_trade_riders text[], p_needed int) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(array_length(p_drop, 1), 0) <> p_needed then
    raise exception 'Bitte genau % Fahrer zum Entlassen auswählen, damit der Kader nicht zu groß wird.', p_needed;
  end if;
  if p_needed = 0 then return; end if;
  if (select count(distinct x) from unnest(p_drop) x) <> p_needed or p_drop && p_trade_riders then
    raise exception 'Zu entlassende Fahrer dürfen nicht Teil des Tauschs sein.';
  end if;
  if (select count(*) from roster_entries where manager_id = p_manager and released_on is null and rider_slug = any (p_drop)) <> p_needed then
    raise exception 'Zu entlassende Fahrer müssen im eigenen Kader stehen.';
  end if;
  if exists (select 1 from waiver_claims where manager_id = p_manager and status = 'pending' and drop_rider = any (p_drop)) then
    raise exception 'Ein Fahrer ist schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen.';
  end if;
end $$;

