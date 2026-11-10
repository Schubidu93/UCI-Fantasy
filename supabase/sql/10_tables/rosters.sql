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

