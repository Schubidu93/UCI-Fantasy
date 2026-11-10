-- Platz eines Fahrers in der Saisonwertung eines Jahres (Summe der UCI-Punkte aus den Rennergebnissen)
create index if not exists race_events_date on race_events (event_date);
-- Saisonwertung je Jahr fest gespeichert (Rang und Punkte je Fahrer), damit das Fahrerfenster sie sofort zeigt.
-- Wird nach jedem Ergebnisabruf für das laufende und das vorige Jahr neu berechnet.
create table if not exists rider_season_stats (
  rider_slug  text not null references riders (pcs_slug) on delete cascade,
  year        int  not null,
  season_rank int  not null,
  points      numeric not null,
  riders      int  not null,       -- Fahrer mit Punkten in dieser Wertung und Saison
  primary key (rider_slug, year)
);

