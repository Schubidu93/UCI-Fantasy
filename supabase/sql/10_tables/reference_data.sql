-- ---------------------------------------------------------------------
-- Stammdaten aus ProCyclingStats (global, für alle Ligen gleich)
-- ---------------------------------------------------------------------

create table if not exists riders (
  pcs_slug       text primary key,              -- stabile ID, z. B. 'tadej-pogacar'
  name           text not null,
  gender         text not null check (gender in ('men', 'women')),
  nation         text,
  team           text,
  uci_rank       int,                           -- aktueller Platz im UCI-Ranking
  ranking_points numeric,                       -- Punkte im UCI-Ranking (52 Wochen)
  inactive       boolean not null default false, -- Karriereende / Sperre
  updated_at     timestamptz not null default now()
);
alter table riders add column if not exists ranking_points numeric;
alter table riders add column if not exists inactive boolean not null default false;
alter table riders add column if not exists birth_date date;
create index if not exists riders_gender_rank on riders (gender, uci_rank);

create table if not exists races (
  pcs_slug   text primary key,                  -- z. B. 'tour-de-france/2026'
  name       text,
  gender     text,
  start_date date,
  end_date   date
);

alter table races add column if not exists uci_class text;   -- z. B. 2.UWT, 1.Pro
alter table races add column if not exists country text;      -- ISO3, z. B. FRA
alter table races add column if not exists dataride_id int;   -- CompetitionId bei UCI DataRide
alter table races add column if not exists loaded_at timestamptz;
alter table races add column if not exists season int;   -- UCI-Saison (beginnt im Herbst des Vorjahres)
create unique index if not exists races_dataride on races (dataride_id, gender) where dataride_id is not null;

-- Etappen bzw. Wertungen eines Rennens (z. B. "Stage 3 · Stage Classification")
create table if not exists race_events (
  id         int primary key,                 -- EventId bei UCI DataRide
  race_slug  text not null references races (pcs_slug) on delete cascade,
  stage_name text,                            -- RaceName: "Stage 3", "Final Classification", …
  stage_no   int,                             -- Reihenfolge der Etappen
  event_name text not null,                   -- "Stage Classification", "General Classification", …
  event_date date,
  winner     text
);
create index if not exists race_events_race on race_events (race_slug);

-- Ergebnisliste je Wertung (Top 25 und alle Plätze mit UCI-Punkten)
create table if not exists event_results (
  event_id    int not null references race_events (id) on delete cascade,
  sort_order  int not null,
  rank        int,
  rank_text   text,                           -- "1", "DNF", …
  rider_name  text not null,
  rider_slug  text,                           -- verknüpft mit riders, falls bekannt
  team        text,
  nation      text,
  result      text,                           -- Zeit bzw. Wert, z. B. "4:04:18" oder "+0:12"
  uci_points  numeric,
  primary key (event_id, sort_order)
);
create index if not exists event_results_rider on event_results (rider_slug);

create table if not exists results (
  id          bigint generated always as identity primary key,
  rider_slug  text not null references riders (pcs_slug) on delete cascade,
  race_slug   text not null,
  label       text not null,                    -- 'result', 'stage-5', 'gc', 'points' …
  result_date date not null,
  rank        int,
  uci_points  numeric not null default 0,
  updated_at  timestamptz not null default now(),
  unique (rider_slug, race_slug, label)
);
alter table results add column if not exists updated_at timestamptz not null default now();
create index if not exists results_rider_date on results (rider_slug, result_date);

create table if not exists sync_status (
  id       int primary key default 1 check (id = 1),
  last_run timestamptz,
  ok       boolean,
  message  text
);
insert into sync_status (id) values (1) on conflict do nothing;

