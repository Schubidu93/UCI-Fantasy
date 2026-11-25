-- =====================================================================
-- Sportart Radsport: alles, worin sich die Datenbank von Athletics Fantasy unterscheidet
-- (Begriffe in Meldungen, Punkteformat, Pool). Die übrigen Dateien sind in beiden Apps
-- gleich und nutzen nur diese Funktionen.
-- =====================================================================

-- Begriffe in Meldungen – wie SPORT in web/sport/config.js
create or replace function _word(p_key text) returns text
language sql immutable as $$
  select case p_key when 'one' then 'Fahrer' when 'oneAcc' then 'Fahrer' when 'many' then 'Fahrer'
                    when 'manyDat' then 'Fahrern' when 'team' then 'Profiteam' when 'teamGen' then 'Profiteams'
                    when 'pool' then 'im UCI-Ranking' when 'importHint' then 'Workflow "Fahrerliste importieren"'
                    when 'emoji' then '🚴' when 'waiver' then 'Waiver' end;
$$;

-- Punkte in Nachrichten wie in der App: ganze Punkte (UCI-Punkte)
create or replace function _fmt_pts(p numeric) returns text
language sql immutable as $$ select round(coalesce(p, 0))::text $$;

-- Darf der Fahrer in dieser Liga geholt werden (Draft, Waiver, freie Phase)? Alle Fahrer der Wertung,
-- auch ohne aktuellen Ranglistenplatz
drop function if exists _selectable(int);
create or replace function _eligible(l leagues, a athletes) returns boolean
language sql stable as $$ select true $$;

-- App: GitHub-Repository (Zeitplaner startet dort die Abläufe), Kurzname (Zeitplan, Kennung), längste Pause des Datenabrufs in Stunden
create or replace function _app(p_key text) returns text
language sql immutable as $$
  select case p_key when 'repo' then 'Schubidu93/UCI-Fantasy' when 'slug' then 'uci-fantasy'
                    when 'sync_hours' then '26' end;   -- Datenabruf täglich 20 Uhr
$$;

-- Nachkommastellen der Punkte (Anzeige, Draft-Prognose)
create or replace function _pts_digits() returns int language sql immutable as $$ select 1 $$;

-- Prognose im Draft-Report: alle Punkte eines Ergebnisses
create or replace function _projection_points(r results) returns numeric
language sql immutable as $$ select r.points $$;

-- Datenabruf zur vollen Stunde (deutsche Zeit), aufgerufen vom Zeitplaner
create or replace function _sport_tick(h int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if h = 6 then perform dispatch_workflow('import-riders.yml'); end if;      -- Fahrer: Rang, Team, Geburtsdatum
  if h = 20 then perform dispatch_workflow('race-results.yml'); end if;      -- Rennergebnisse, Kalender, Punkte
end $$;
