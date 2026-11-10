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

