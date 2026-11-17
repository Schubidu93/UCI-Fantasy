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
          coalesce('Zuschlag: ' || string_agg(_rname(w.add_athlete), ', ') filter (where w.status = 'won'), 'Kein Zuschlag')
          || coalesce(' · ohne Zuschlag: ' || string_agg(_rname(w.add_athlete), ', ') filter (where w.status = 'lost'), ''),
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
  if n > 0 then perform _push_soon(); end if;   -- Waiver-Ergebnisse und ausgeführte Tausche sofort melden
  return n;
end $$;

-- Täglich nach dem Ergebnisabruf (nur Service-Key): Spieltage abschließen und
-- 7 Tage nach Abschluss einfrieren.
-- Push „Neue Punkte“: neue Punkte von Fahrern im eigenen Kader, die für einen Spieltag zählen
-- (bei Aufstellung nur Aufgestellte), höchstens 14 Tage alt; eine Nachricht je Manager und Abruf
create or replace function notify_new_points() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  create temp table if not exists _np (league_id uuid, league_name text, manager_id uuid, athlete_id text,
                                       competition_id text, label text, points numeric) on commit drop;
  delete from _np;
  insert into _np
  select l.id, l.name, x.manager_id, x.athlete_id, x.competition_id, x.label, x.points
    from leagues l cross join lateral _score_rows(l.id) x
   where l.status = 'active' and x.points > 0 and x.result_date >= current_date - 14
     and not exists (select 1 from point_pushes p where p.manager_id = x.manager_id and p.athlete_id = x.athlete_id
                       and p.competition_id = x.competition_id and p.label = x.label);
  for r in
    with per as (   -- je Fahrer und Rennen zusammenfassen (z. B. Etappe + Gesamtwertung)
      select league_id, league_name, manager_id, athlete_id, competition_id, sum(points) pts
        from _np group by 1, 2, 3, 4, 5)
    select per.league_id, per.league_name, per.manager_id,
           string_agg(_rname(per.athlete_id) || ' +' || round(per.pts)::text
                      || coalesce(' (' || c.name || ')', ''), ' · ' order by per.pts desc) txt
      from per left join competitions c on c.id = per.competition_id
     group by 1, 2, 3
  loop
    perform _notify(r.manager_id, '📈 Neue Punkte', r.league_name || ': ' || r.txt, '#/league/' || r.league_id || '/points');
    n := n + 1;
  end loop;
  insert into point_pushes (manager_id, athlete_id, competition_id, label)
  select distinct manager_id, athlete_id, competition_id, label from _np on conflict do nothing;
  if n > 0 and exists (select 1 from notifications where sent_at is null) then
    begin
      perform dispatch_workflow('push.yml');
    exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
    end;
  end if;
  return n;
end $$;

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
    insert into score_snapshot (league_id, matchday_id, manager_id, athlete_id, competition_id, label, result_date, points)
      select md.league_id, s.matchday_id, s.manager_id, s.athlete_id, s.competition_id, s.label, s.result_date, s.points
        from _score_rows(md.league_id) s where s.matchday_id = md.id;
    update matchdays set frozen = true where id = md.id;
  end loop;
  update leagues set status = 'finished' where status = 'active' and season_end < current_date;
  begin
    perform notify_new_points();
  exception when others then raise warning 'notify_new_points: %', sqlerrm;
  end;
  update sync_status set last_run = now(), ok = true, message = null where id = 1;
end $$;
