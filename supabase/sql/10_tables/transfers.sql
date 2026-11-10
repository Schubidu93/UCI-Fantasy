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

