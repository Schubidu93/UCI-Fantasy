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

