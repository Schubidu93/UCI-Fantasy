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

