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

