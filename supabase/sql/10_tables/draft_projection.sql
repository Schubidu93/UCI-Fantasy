-- läuft alle 15 Minuten
-- Wochen-Zusammenfassung (montags): Punkte der letzten 7 Tage, Tabellenplatz, bester Fahrer – je Manager mit Push
-- Draft-Report: bestmögliche Punkte jedes Kaders im Vorjahr – je Spieltag (Zeitraum ein Jahr früher) die besten
-- x der y gedrafteten Fahrer (x = wertende Fahrer laut Einstellung, y = Kadergröße). Ergebnis wird zwischengespeichert.
create table if not exists draft_projection (
  league_id  uuid not null references leagues (id) on delete cascade,
  manager_id uuid not null references managers (id) on delete cascade,
  points     numeric not null,
  per_md     jsonb not null default '{}',
  signature  text not null,          -- Spieltage + Wertungsmodus; ändert sich etwas, wird neu gerechnet
  computed_at timestamptz not null default now(),
  primary key (league_id, manager_id)
);
