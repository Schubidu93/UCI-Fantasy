create or replace function _claim_valid(c waiver_claims, l leagues) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if c.drop_rider is null then
    if _open_roster_slots(c.manager_id) <= 0 then return 'Kader ist voll'; end if;
  elsif not exists (select 1 from roster_entries where manager_id = c.manager_id and rider_slug = c.drop_rider and released_on is null) then
    return 'Abzugebender Fahrer nicht mehr im Kader';
  end if;
  if not _rider_free(l.id, c.add_rider, now()) then return 'Fahrer schon vergeben'; end if;
  if not _team_limit_ok(c.manager_id, c.add_rider, c.drop_rider) then return 'Grenze pro Profiteam'; end if;
  if l.waiver_mode = 'faab' and c.bid > (select budget_left from managers where id = c.manager_id) then
    return 'Restbudget reicht nicht';
  end if;
  return null;
end $$;

create or replace function _execute_claim(c waiver_claims, l leagues, md matchdays) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _release(l.id, c.manager_id, c.drop_rider, md.starts_on);
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
  values (l.id, c.manager_id, c.add_rider, case when l.waiver_mode = 'faab' then c.bid else 0 end, 'waiver', md.starts_on);
  if l.waiver_mode = 'faab' then
    update managers set budget_left = budget_left - c.bid where id = c.manager_id;
  end if;
  -- steht der abgegebene Fahrer in einer Aufstellung ab diesem Spieltag, rückt der neue nach
  update lineups x set rider_slug = c.add_rider
    from matchdays m where m.id = x.matchday_id and m.league_id = l.id and m.starts_on >= md.starts_on
     and x.manager_id = c.manager_id and x.rider_slug = c.drop_rider;
  update waiver_claims set status = 'won', processed_at = now(), matchday_id = md.id where id = c.id;
  -- andere Anträge mit demselben abzugebenden Fahrer werden ungültig
  update waiver_claims set status = 'lost', note = 'Abzugebender Fahrer schon getauscht', processed_at = now(), matchday_id = md.id
   where manager_id = c.manager_id and status = 'pending' and c.drop_rider is not null and drop_rider = c.drop_rider;
end $$;

