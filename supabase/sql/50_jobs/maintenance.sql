-- =====================================================================
-- Stichtage und Spieltags-Status
-- =====================================================================

-- Arbeitet alle fälligen Stichtage ab (Tausch, Waiver, Wertungsmodus übernehmen).
-- Darf jeder angemeldete Nutzer aufrufen; die App tut das beim Öffnen.
create or replace function process_due(p_league uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare md matchdays; n int := 0;
begin
  for md in select m.* from matchdays m join leagues l on l.id = m.league_id
             where ((not m.waivers_done and coalesce(m.waiver_deadline, m.deadline) <= now())
                    or (not m.locked and m.deadline <= now()))
               and l.status = 'active' and (p_league is null or m.league_id = p_league)
             order by m.deadline
             for update of m skip locked loop
    -- Stichtag: Tausche ausführen, Wertungsmodus festhalten, Kader und Aufstellung sind ab jetzt fest
    if not md.locked and md.deadline <= now() then
      update matchdays m set scoring_mode = l.scoring_mode, lineup_size = l.lineup_size
        from leagues l where l.id = m.league_id and m.id = md.id;
      perform _process_trades(md.id);
    end if;
    -- Waiver-Runde (im zweiteiligen Modus vor dem Stichtag, danach beginnt die freie Phase)
    if not md.waivers_done and coalesce(md.waiver_deadline, md.deadline) <= now() then
      perform _process_waivers(md.id);
      perform _notify(w.manager_id, '📋 Waiver-Ergebnis',
          coalesce('Zuschlag: ' || string_agg(_rname(w.add_rider), ', ') filter (where w.status = 'won'), 'Kein Zuschlag')
          || coalesce(' · ohne Zuschlag: ' || string_agg(_rname(w.add_rider), ', ') filter (where w.status = 'lost'), ''),
          '#/league/' || md.league_id || '/waiver')
         from waiver_claims w where w.matchday_id = md.id and w.processed_at >= now() - interval '1 minute'
         group by w.manager_id;
      update matchdays set waivers_done = true where id = md.id;
      update leagues set last_waiver_run = now() where id = md.league_id;
    end if;
    if md.deadline <= now() then update matchdays set locked = true where id = md.id; end if;
    n := n + 1;
  end loop;
  update matchdays set status = 'running'
   where status = 'planned' and starts_on <= current_date and (p_league is null or league_id = p_league);
  return n;
end $$;

-- Täglich nach dem Ergebnisabruf (nur Service-Key): Spieltage abschließen und
-- 7 Tage nach Abschluss einfrieren.
create or replace function run_maintenance() returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays;
begin
  perform process_due(null);
  for md in update matchdays set status = 'closed', closed_at = now() where status = 'running' and ends_on < current_date
             returning * loop
    perform _notify(t.manager_id, '🏁 ' || md.name || ' abgeschlossen',
        coalesce((select round(sum(p.points))::text from _league_points(md.league_id) p
                   where p.matchday_id = md.id and p.manager_id = t.manager_id), '0')
        || ' Punkte · Gesamt Platz ' || t."position", '#/league/' || md.league_id || '/table')
       from _league_table(md.league_id) t;
  end loop;
  for md in select * from matchdays where status = 'closed' and not frozen and closed_at <= now() - interval '7 days' loop
    insert into score_snapshot (league_id, matchday_id, manager_id, rider_slug, race_slug, label, result_date, points)
      select md.league_id, s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, s.label, s.result_date, s.points
        from _score_rows(md.league_id) s where s.matchday_id = md.id;
    update matchdays set frozen = true where id = md.id;
  end loop;
  update leagues set status = 'finished' where status = 'active' and season_end < current_date;
  update sync_status set last_run = now(), ok = true, message = null where id = 1;
end $$;

