-- =====================================================================
-- UCI Fantasy – Datenbankschema für Supabase: Tabellen
--
-- Das Schema ist nach Themen auf supabase/schema/NN_*.sql verteilt und wird in Dateireihenfolge
-- eingespielt (Workflow „Datenbank einrichten“, Tests). Alles ist wiederholbar: Tabellen werden nur
-- angelegt, wenn sie fehlen; Funktionen und Regeln werden ersetzt.
-- Alle Schreibzugriffe der App laufen über Datenbankfunktionen (RPC); direkt schreiben darf nur der
-- Service-Key (GitHub-Workflows).
-- =====================================================================

create extension if not exists pgcrypto;
create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- Umstieg vom ersten Entwurf (Tabelle league_members): Die alten
-- Ligatabellen werden ersetzt – aber nur, solange noch keine Liga existiert.
-- profiles, riders, races und results bleiben erhalten.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.league_members') is not null then
    if exists (select 1 from public.leagues) then
      raise exception 'Alte Struktur enthält schon Ligen – bitte melden, dann wird migriert statt ersetzt.';
    end if;
    drop view if exists public.standings, public.matchday_scores, public.matchday_rider_points cascade;
    drop table if exists public.point_corrections, public.trades, public.waiver_claims, public.draft_bids,
                         public.draft_lots, public.lineups, public.roster_entries, public.matchdays,
                         public.league_members, public.leagues cascade;
    drop function if exists public.is_member(uuid) cascade;
    drop function if exists public.is_admin(uuid) cascade;
  end if;
  -- alte Spaltennamen der Stammdaten angleichen
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'riders' and column_name = 'prev_year_rank') then
    alter table public.riders rename column prev_year_rank to uci_rank;
  end if;
end $$;

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

-- ---------------------------------------------------------------------
-- Ligen und Manager
-- ---------------------------------------------------------------------

create table if not exists leagues (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  admin_user      uuid not null references auth.users (id),
  invite_code     text not null unique default encode(gen_random_bytes(5), 'hex'),
  max_managers    int  not null default 8   check (max_managers between 2 and 20),
  roster_size     int  not null default 15  check (roster_size between 5 and 30),
  scoring_mode    text not null default 'full' check (scoring_mode in ('full', 'lineup')),
  lineup_size     int  check (lineup_size is null or lineup_size between 1 and roster_size),
  budget          int  not null default 100 check (budget = 100),
  min_bid         int  not null default 1   check (min_bid = 1),
  max_per_team    int  check (max_per_team is null or max_per_team between 1 and roster_size),
  draft_mode      text not null default 'live' check (draft_mode in ('live', 'blind', 'snake', 'offline')),
  draft_order     text not null default 'ranking' check (draft_order in ('ranking', 'nominate')),
  bid_seconds     int  not null default 15  check (bid_seconds between 5 and 600),  -- Sekunden pro Gebot bzw. Pick
  waiver_mode     text not null default 'priority' check (waiver_mode in ('priority', 'faab')),
  gender          text not null default 'men' check (gender in ('men', 'women')),
  season_start    date not null,
  season_end      date not null,
  status          text not null default 'setup' check (status in ('setup', 'drafting', 'active', 'finished')),
  last_waiver_run timestamptz,
  draft_at        timestamptz,                -- geplanter Draft-Start
  created_at      timestamptz not null default now(),
  check (season_end > season_start)
);

alter table leagues add column if not exists draft_at timestamptz;
-- Transfers: nur Waiver (Stichtag = Sperre) oder zweiteilig: Waiver-Runde, danach freie Phase bis zum Spieltagstart
alter table leagues add column if not exists transfer_mode text not null default 'waiver_free';
do $$ begin
  alter table leagues add constraint leagues_transfer_mode_check check (transfer_mode in ('waiver', 'waiver_free'));
exception when duplicate_object then null; end $$;
alter table leagues add column if not exists prev_league uuid references leagues (id) on delete set null;  -- Vorsaison
alter table leagues add column if not exists keeper_count int not null default 0;      -- Fahrer, die man behalten darf
alter table leagues add column if not exists keeper_surcharge int not null default 5;  -- Aufschlag auf den Vorjahrespreis
do $$ begin
  alter table leagues add constraint leagues_keeper_check check (keeper_count between 0 and 10 and keeper_surcharge between 0 and 50);
exception when duplicate_object then null; end $$;

create table if not exists managers (
  id             uuid primary key default gen_random_uuid(),
  league_id      uuid not null references leagues (id) on delete cascade,
  user_id        uuid references auth.users (id) on delete set null,  -- null = Platzhalter
  team_name      text not null,
  budget_left    int  not null default 100,
  draft_position int,
  joined_at      timestamptz not null default now(),
  unique (league_id, user_id),
  unique (league_id, team_name)
);

-- ---------------------------------------------------------------------
-- Draft
-- ---------------------------------------------------------------------

alter table managers add column if not exists prev_manager uuid references managers (id) on delete set null;

-- Keeper: aus der Vorsaison behaltene Fahrer (werden beim Draft-Start in den Kader gesetzt)
create table if not exists keepers (
  league_id  uuid not null references leagues (id) on delete cascade,
  manager_id uuid not null references managers (id) on delete cascade,
  rider_slug text not null references riders (pcs_slug),
  price      int  not null default 0,
  primary key (manager_id, rider_slug),
  unique (league_id, rider_slug)
);

create table if not exists draft_state (
  league_id        uuid primary key references leagues (id) on delete cascade,
  status           text not null default 'pending' check (status in ('pending', 'running', 'paused', 'done')),
  phase            text not null default 'auction' check (phase in ('auction', 'fill', 'snake')),
  lot_no           int  not null default 0,
  current_rider    text references riders (pcs_slug),
  current_bid      int  not null default 0,
  current_bidder   uuid references managers (id) on delete set null,
  deadline         timestamptz,
  paused_remaining interval,
  nominator        uuid references managers (id) on delete set null,
  updated_at       timestamptz not null default now()
);

-- Snake-Draft nachrüsten (bestehende Datenbanken)
do $$
begin
  alter table leagues drop constraint if exists leagues_draft_mode_check;
  alter table leagues add constraint leagues_draft_mode_check check (draft_mode in ('live', 'blind', 'snake', 'offline'));
  alter table leagues drop constraint if exists leagues_bid_seconds_check;
  alter table leagues add constraint leagues_bid_seconds_check check (bid_seconds between 5 and 600);
  alter table draft_state drop constraint if exists draft_state_phase_check;
  alter table draft_state add constraint draft_state_phase_check check (phase in ('auction', 'fill', 'snake', 'tiebreak'));
end $$;

-- Blind-Auktion: verdeckte Gebote je Fahrer; bei Gleichstand Stechen (+1) unter den Gleichauf-Bietern
alter table draft_state add column if not exists sealed_done uuid[] not null default '{}';  -- wer schon geboten hat (ohne Betrag)
alter table draft_state add column if not exists tie_bidders uuid[];                      -- Teilnehmer am Stechen
alter table draft_state add column if not exists tie_ptr int not null default 0;          -- reihum: Draft-Position des letzten Vorrangs
create table if not exists draft_sealed (
  league_id  uuid not null references leagues (id) on delete cascade,
  lot_no     int  not null,
  manager_id uuid not null references managers (id) on delete cascade,
  amount     int  not null check (amount > 0),
  created_at timestamptz not null default now(),
  primary key (league_id, manager_id)
);

create table if not exists draft_lots (
  id         bigint generated always as identity primary key,
  league_id  uuid not null references leagues (id) on delete cascade,
  lot_no     int  not null,
  rider_slug text not null references riders (pcs_slug),
  manager_id uuid references managers (id) on delete set null,  -- null = übersprungen
  price      int  not null default 0,
  created_at timestamptz not null default now(),
  unique (league_id, rider_slug)
);

create table if not exists draft_bids (
  id         bigint generated always as identity primary key,
  league_id  uuid not null references leagues (id) on delete cascade,
  lot_no     int  not null,
  manager_id uuid not null references managers (id) on delete cascade,
  amount     int  not null,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Kader
-- Ein Eintrag pro Zugehörigkeit. Ergebnisse zählen ab acquired_on
-- (einschließlich) bis released_on (ausschließlich).
-- ---------------------------------------------------------------------

create table if not exists roster_entries (
  id          bigint generated always as identity primary key,
  league_id   uuid not null references leagues (id) on delete cascade,
  manager_id  uuid not null references managers (id) on delete cascade,
  rider_slug  text not null references riders (pcs_slug),
  price       int  not null default 0,
  source      text not null,
  acquired_on date not null,
  acquired_at timestamptz not null default now(),
  released_on date,
  released_at timestamptz
);
alter table roster_entries drop constraint if exists roster_entries_source_check;
alter table roster_entries add constraint roster_entries_source_check
  check (source in ('draft', 'offline', 'waiver', 'trade', 'admin', 'free'));
create unique index if not exists roster_active_rider on roster_entries (league_id, rider_slug) where released_on is null;
create index if not exists roster_manager on roster_entries (manager_id);

-- ---------------------------------------------------------------------
-- Spieltage, Aufstellungen
-- ---------------------------------------------------------------------

create table if not exists matchdays (
  id           uuid primary key default gen_random_uuid(),
  league_id    uuid not null references leagues (id) on delete cascade,
  name         text not null,
  starts_on    date not null,
  ends_on      date not null,
  deadline     timestamptz not null,           -- Stichtag für Kaderänderungen
  status       text not null default 'planned' check (status in ('planned', 'running', 'closed')),
  waivers_done boolean not null default false,  -- Stichtag abgearbeitet
  closed_at    timestamptz,
  frozen       boolean not null default false,  -- Ergebnis eingefroren (7 Tage nach Abschluss)
  scoring_mode text,                            -- beim Stichtag aus der Liga übernommen
  lineup_size  int,
  check (ends_on >= starts_on),
  constraint matchdays_no_overlap exclude using gist (
    league_id with =, daterange(starts_on, ends_on, '[]') with &&)
);

alter table matchdays add column if not exists waiver_deadline timestamptz;   -- Waiver-Auswertung (null = am Stichtag)
alter table matchdays add column if not exists locked boolean not null default false;   -- Kader/Aufstellung fest (Stichtag erreicht)
update matchdays set locked = true where not locked and waivers_done and deadline <= now();

create table if not exists lineups (
  matchday_id uuid not null references matchdays (id) on delete cascade,
  manager_id  uuid not null references managers (id) on delete cascade,
  rider_slug  text not null references riders (pcs_slug),
  primary key (matchday_id, manager_id, rider_slug)
);

-- ---------------------------------------------------------------------
-- Waiver und Tausch
-- ---------------------------------------------------------------------

create table if not exists waiver_claims (
  id           uuid primary key default gen_random_uuid(),
  league_id    uuid not null references leagues (id) on delete cascade,
  manager_id   uuid not null references managers (id) on delete cascade,
  add_rider    text not null references riders (pcs_slug),
  drop_rider   text not null references riders (pcs_slug),
  priority     int  not null default 1,
  bid          int  not null default 0,
  status       text not null default 'pending' check (status in ('pending', 'won', 'lost', 'cancelled')),
  note         text,
  matchday_id  uuid references matchdays (id) on delete set null,
  created_at   timestamptz not null default now(),
  processed_at timestamptz
);

create table if not exists trades (
  id           uuid primary key default gen_random_uuid(),
  league_id    uuid not null references leagues (id) on delete cascade,
  from_manager uuid not null references managers (id) on delete cascade,
  to_manager   uuid not null references managers (id) on delete cascade,
  give_riders  text[] not null,   -- gibt from_manager ab
  take_riders  text[] not null,   -- bekommt from_manager
  status       text not null default 'proposed'
               check (status in ('proposed', 'accepted', 'declined', 'cancelled', 'vetoed', 'done', 'failed')),
  note         text,
  created_at   timestamptz not null default now(),
  accepted_at  timestamptz,
  done_at      timestamptz
);
-- Waiver ohne Abgabe, wenn der Kader nicht voll ist (z. B. nach einem ungleichen Tausch)
alter table waiver_claims alter column drop_rider drop not null;

-- Ungleiche Tausche: wer mehr Fahrer bekommt, entlässt dafür zusätzlich eigene Fahrer
alter table trades add column if not exists from_drop text[] not null default '{}';   -- entlässt from_manager (beim Angebot gewählt)
alter table trades add column if not exists to_drop   text[] not null default '{}';   -- entlässt to_manager (bei Annahme gewählt)

-- ---------------------------------------------------------------------
-- Punkte: Korrekturen, eingefrorene Stände, Protokoll
-- ---------------------------------------------------------------------

create table if not exists point_overrides (
  id          bigint generated always as identity primary key,
  league_id   uuid not null references leagues (id) on delete cascade,
  matchday_id uuid not null references matchdays (id) on delete cascade,
  manager_id  uuid not null references managers (id) on delete cascade,
  rider_slug  text not null references riders (pcs_slug),
  points      numeric not null,
  reason      text,
  created_by  uuid,
  created_at  timestamptz not null default now(),
  unique (matchday_id, manager_id, rider_slug)
);

create table if not exists score_snapshot (
  league_id   uuid not null references leagues (id) on delete cascade,
  matchday_id uuid not null references matchdays (id) on delete cascade,
  manager_id  uuid not null references managers (id) on delete cascade,
  rider_slug  text not null,
  race_slug   text not null,
  label       text not null,
  result_date date not null,
  points      numeric not null
);
create index if not exists score_snapshot_md on score_snapshot (matchday_id);

create table if not exists admin_log (
  id         bigint generated always as identity primary key,
  league_id  uuid not null references leagues (id) on delete cascade,
  user_id    uuid,
  action     text not null,
  details    jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Push-Benachrichtigungen
-- ---------------------------------------------------------------------

-- Interne Einstellungen (z. B. VAPID-Schlüssel) – nur für den Service-Key lesbar
create table if not exists app_config (
  key   text primary key,
  value text not null
);

create table if not exists push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);

-- Warteschlange: wird alle 15 Minuten vom Workflow "Benachrichtigungen senden" verschickt
create table if not exists notifications (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users (id) on delete cascade,
  title      text not null,
  body       text,
  url        text,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
alter table notifications add column if not exists expires_at timestamptz;   -- danach nicht mehr senden (z. B. „Du bist dran“)
create index if not exists notifications_unsent on notifications (created_at) where sent_at is null;

-- Schon gemeldete Punkte („Neue Punkte“-Push): je Manager, Fahrer, Rennen und Etappe/Wertung genau einmal
create table if not exists point_pushes (
  manager_id uuid not null references managers (id) on delete cascade,
  rider_slug text not null,
  race_slug  text not null,
  label      text not null,
  created_at timestamptz not null default now(),
  primary key (manager_id, rider_slug, race_slug, label)
);
alter table point_pushes enable row level security;   -- keine Policies: nur intern
