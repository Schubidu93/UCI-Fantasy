-- =====================================================================
-- Sportart Radsport: alles, worin sich die Datenbank von Runner Fantasy unterscheidet
-- (Begriffe in Meldungen, Punkteformat, Pool). Die übrigen Dateien sind in beiden Apps
-- gleich und nutzen nur diese Funktionen.
-- =====================================================================

-- Begriffe in Meldungen – wie SPORT in web/sport/config.js
create or replace function _word(p_key text) returns text
language sql immutable as $$
  select case p_key when 'one' then 'Fahrer' when 'oneAcc' then 'Fahrer' when 'many' then 'Fahrer'
                    when 'manyDat' then 'Fahrern' when 'team' then 'Profiteam' when 'teamGen' then 'Profiteams'
                    when 'pool' then 'im UCI-Ranking' when 'importHint' then 'Workflow "Fahrerliste importieren"'
                    when 'emoji' then '🚴' end;
$$;

-- Punkte in Nachrichten wie in der App: ganze Punkte (UCI-Punkte)
create or replace function _fmt_pts(p numeric) returns text
language sql immutable as $$ select round(coalesce(p, 0))::text $$;

-- Darf geholt werden (Draft, Waiver, freie Phase)? Alle Fahrer der Wertung, auch ohne aktuellen Ranglistenplatz
create or replace function _selectable(p_pool_rank int) returns boolean
language sql immutable as $$ select true $$;
