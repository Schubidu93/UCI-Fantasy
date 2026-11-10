create table if not exists lineups (
  matchday_id uuid not null references matchdays (id) on delete cascade,
  manager_id  uuid not null references managers (id) on delete cascade,
  rider_slug  text not null references riders (pcs_slug),
  primary key (matchday_id, manager_id, rider_slug)
);

