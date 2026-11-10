-- Einmalig: Spieltage nach der alten festen Vorlage (Richtwerte 2026) an die echten Termine 2027 anpassen,
-- damit kein WorldTour-Rennen auf zwei Spieltage fällt (Romandie, Tour ab 2.7., Vuelta bis 26.9.).
-- Nur Ligen, deren 7 Spieltage noch exakt der Vorlage entsprechen und alle noch geplant sind.
do $$
declare l record; m record;
  v_old text[][] := array[['Saisonauftakt','2027-01-01','2027-02-28'], ['Frühjahrsklassiker','2027-03-01','2027-04-30'],
    ['Giro','2027-05-01','2027-06-01'], ['Juni-Rundfahrten','2027-06-02','2027-07-03'], ['Tour','2027-07-04','2027-07-31'],
    ['Vuelta','2027-08-01','2027-09-14'], ['Herbst','2027-09-15','2027-10-31']];
  -- Reihenfolge so, dass sich nie zwei Spieltage überschneiden
  v_new text[][] := array[['Giro','2027-05-08','2027-05-30'], ['Frühjahrsklassiker','2027-03-01','2027-05-07'],
    ['Juni-Rundfahrten','2027-05-31','2027-07-01'], ['Tour','2027-07-02','2027-07-25'], ['Herbst','2027-09-27','2027-10-31'],
    ['Vuelta','2027-07-26','2027-09-26']];
  i int; n int;
begin
  for l in select id from leagues loop
    select count(*) into n from matchdays where league_id = l.id;
    if n <> 7 or exists (select 1 from matchdays where league_id = l.id and (status <> 'planned' or waivers_done)) then continue; end if;
    n := 0;
    for i in 1..7 loop
      if exists (select 1 from matchdays where league_id = l.id and name = v_old[i][1]
                  and starts_on = v_old[i][2]::date and ends_on = v_old[i][3]::date) then n := n + 1; end if;
    end loop;
    if n <> 7 then continue; end if;
    for i in 1..6 loop
      update matchdays set starts_on = v_new[i][2]::date, ends_on = v_new[i][3]::date
       where league_id = l.id and name = v_new[i][1];
    end loop;
    for m in select id, starts_on from matchdays where league_id = l.id order by starts_on loop
      update matchdays set deadline = _default_deadline(l.id, m.starts_on),
                           waiver_deadline = _default_waiver_deadline(l.id, m.starts_on, m.id)
       where id = m.id;
    end loop;
    raise notice 'Spieltage an Termine 2027 angepasst: Liga %', l.id;
  end loop;
end $$;
