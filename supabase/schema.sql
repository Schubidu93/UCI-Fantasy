-- =====================================================================
-- UCI Fantasy – Datenbankschema für Supabase
--
-- Einmal komplett im Supabase SQL-Editor ausführen (oder per Workflow
-- "Datenbank einrichten"). Das Skript ist wiederholbar: Tabellen werden nur
-- angelegt, wenn sie fehlen; Funktionen und Regeln werden ersetzt.
--
-- Alle Schreibzugriffe der App laufen über die Funktionen (RPC) unten.
-- Direkt schreiben darf nur der Service-Key (GitHub-Workflows).
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
  draft_mode      text not null default 'live' check (draft_mode in ('live', 'snake', 'offline')),
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
  alter table leagues add constraint leagues_draft_mode_check check (draft_mode in ('live', 'snake', 'offline'));
  alter table leagues drop constraint if exists leagues_bid_seconds_check;
  alter table leagues add constraint leagues_bid_seconds_check check (bid_seconds between 5 and 600);
  alter table draft_state drop constraint if exists draft_state_phase_check;
  alter table draft_state add constraint draft_state_phase_check check (phase in ('auction', 'fill', 'snake'));
end $$;

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
  source      text not null check (source in ('draft', 'offline', 'waiver', 'trade', 'admin')),
  acquired_on date not null,
  acquired_at timestamptz not null default now(),
  released_on date,
  released_at timestamptz
);
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

-- =====================================================================
-- Hilfsfunktionen
-- =====================================================================

create or replace function is_member(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from managers where league_id = p_league and user_id = auth.uid());
$$;

create or replace function is_admin(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from leagues where id = p_league and admin_user = auth.uid());
$$;

create or replace function my_manager(p_league uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from managers where league_id = p_league and user_id = auth.uid();
$$;

create or replace function server_now() returns timestamptz
language sql stable as $$ select now(); $$;

create or replace function _is_service() returns boolean
language sql stable as $$
  select coalesce(auth.role(), '') = 'service_role' or session_user in ('postgres', 'supabase_admin');
$$;

create or replace function _require_member(p_league uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  v := my_manager(p_league);
  if v is null then raise exception 'Du bist kein Mitglied dieser Liga.'; end if;
  return v;
end $$;

create or replace function _require_admin(p_league uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(p_league) then raise exception 'Nur der Liga-Admin darf das.'; end if;
end $$;

create or replace function _log(p_league uuid, p_action text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_log (league_id, user_id, action, details) values (p_league, auth.uid(), p_action, p_details);
$$;

-- Freie Kaderplätze eines Managers
create or replace function _open_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries r where r.manager_id = m.id and r.released_on is null)::int
  from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Höchstgebot im Draft: Restbudget minus (offene Plätze − 1) × Mindestgebot
create or replace function _max_bid(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when _open_slots(m.id) <= 0 then 0 else m.budget_left - (_open_slots(m.id) - 1) end
  from managers m where m.id = p_manager;
$$;

-- Würde der Manager mit diesem Fahrer die Grenze pro Profiteam überschreiten?
create or replace function _team_limit_ok(p_manager uuid, p_rider text, p_without text default null) returns boolean
language sql stable security definer set search_path = public as $$
  select l.max_per_team is null
      or rd.team is null
      or (select count(*) from roster_entries re join riders x on x.pcs_slug = re.rider_slug
          where re.manager_id = m.id and re.released_on is null and x.team = rd.team
            and re.rider_slug is distinct from p_without) < l.max_per_team
  from managers m join leagues l on l.id = m.league_id, riders rd
  where m.id = p_manager and rd.pcs_slug = p_rider;
$$;

-- Ist ein Fahrer in der Liga frei? Abgegebene Fahrer sind gesperrt, wenn sie
-- seit p_locked_since abgegeben wurden (= bis zum nächsten Stichtag).
create or replace function _rider_free(p_league uuid, p_rider text, p_locked_since timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from riders r join leagues l on l.id = p_league
                 where r.pcs_slug = p_rider and r.gender = l.gender)
     and not exists (select 1 from roster_entries
                     where league_id = p_league and rider_slug = p_rider
                       and (released_on is null or released_at >= p_locked_since));
$$;

create or replace function _release(p_league uuid, p_manager uuid, p_rider text, p_on date) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update roster_entries set released_on = p_on, released_at = now()
   where league_id = p_league and manager_id = p_manager and rider_slug = p_rider and released_on is null;
  return found;
end $$;

-- =====================================================================
-- Liga anlegen, beitreten, verwalten
-- =====================================================================

create or replace function create_league(p_name text, p_team_name text, p_settings jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; s jsonb := coalesce(p_settings, '{}');
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  insert into leagues (name, admin_user, max_managers, roster_size, scoring_mode, lineup_size, max_per_team,
                       draft_mode, draft_order, bid_seconds, waiver_mode, gender, season_start, season_end)
  values (p_name, auth.uid(),
          coalesce((s->>'max_managers')::int, 8),
          coalesce((s->>'roster_size')::int, 15),
          coalesce(s->>'scoring_mode', 'full'),
          (s->>'lineup_size')::int,
          (s->>'max_per_team')::int,
          coalesce(s->>'draft_mode', 'live'),
          coalesce(s->>'draft_order', 'ranking'),
          coalesce((s->>'bid_seconds')::int, 15),
          coalesce(s->>'waiver_mode', 'priority'),
          coalesce(s->>'gender', 'men'),
          coalesce((s->>'season_start')::date, make_date(extract(year from current_date)::int + 1, 1, 1)),
          coalesce((s->>'season_end')::date, make_date(extract(year from current_date)::int + 1, 10, 31)))
  returning id into v_id;
  insert into managers (league_id, user_id, team_name) values (v_id, auth.uid(), p_team_name);
  insert into draft_state (league_id) values (v_id);
  return v_id;
end $$;

-- Liga-Infos für die Beitrittsseite (ohne Mitglied zu sein)
create or replace function league_by_code(p_code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'name', l.name, 'status', l.status, 'max_managers', l.max_managers,
    'members', (select count(*) from managers m where m.league_id = l.id),
    'already_member', exists (select 1 from managers m where m.league_id = l.id and m.user_id = auth.uid()),
    'placeholders', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'team_name', m.team_name))
                              from managers m where m.league_id = l.id and m.user_id is null), '[]'))
  from leagues l where l.invite_code = p_code;
$$;

create or replace function join_league(p_code text, p_team_name text, p_claim uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leagues;
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  select * into l from leagues where invite_code = p_code;
  if not found then raise exception 'Einladungslink ungültig.'; end if;
  if exists (select 1 from managers where league_id = l.id and user_id = auth.uid()) then return l.id; end if;
  if p_claim is not null then
    update managers set user_id = auth.uid(), team_name = coalesce(nullif(trim(p_team_name), ''), team_name)
     where id = p_claim and league_id = l.id and user_id is null;
    if not found then raise exception 'Dieser Platz ist schon vergeben.'; end if;
    return l.id;
  end if;
  if l.status <> 'setup' then raise exception 'Der Draft hat schon begonnen. Übernimm einen freien Platz.'; end if;
  if (select count(*) from managers where league_id = l.id) >= l.max_managers then
    raise exception 'Die Liga ist voll.';
  end if;
  insert into managers (league_id, user_id, team_name) values (l.id, auth.uid(), p_team_name);
  return l.id;
end $$;

create or replace function set_team_name(p_league uuid, p_team_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update managers set team_name = p_team_name where id = _require_member(p_league);
end $$;

create or replace function add_placeholder_manager(p_league uuid, p_team_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v uuid; l leagues;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league;
  if l.status <> 'setup' then raise exception 'Nur vor dem Draft möglich.'; end if;
  if (select count(*) from managers where league_id = p_league) >= l.max_managers then raise exception 'Die Liga ist voll.'; end if;
  insert into managers (league_id, team_name) values (p_league, p_team_name) returning id into v;
  return v;
end $$;

-- Vor dem Draft: Manager entfernen. Danach: Konto lösen, Kader bleibt für einen Nachfolger.
create or replace function remove_manager(p_league uuid, p_manager uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues; m managers;
begin
  select * into l from leagues where id = p_league;
  select * into m from managers where id = p_manager and league_id = p_league;
  if not found then raise exception 'Manager nicht gefunden.'; end if;
  if not (is_admin(p_league) or m.user_id = auth.uid()) then raise exception 'Keine Berechtigung.'; end if;
  if m.user_id = l.admin_user then raise exception 'Übertrage zuerst die Admin-Rechte.'; end if;
  if l.status = 'setup' then
    delete from managers where id = p_manager;
  else
    update managers set user_id = null where id = p_manager;
  end if;
  perform _log(p_league, 'remove_manager', jsonb_build_object('manager', p_manager, 'team', m.team_name));
end $$;

create or replace function transfer_admin(p_league uuid, p_manager uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  perform _require_admin(p_league);
  select user_id into v from managers where id = p_manager and league_id = p_league;
  if v is null then raise exception 'Dieser Manager hat kein Konto.'; end if;
  update leagues set admin_user = v where id = p_league;
  perform _log(p_league, 'transfer_admin', jsonb_build_object('manager', p_manager));
end $$;

create or replace function update_league_settings(p_league uuid, p_settings jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues; s jsonb := p_settings;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league for update;
  if l.status = 'setup' then
    update leagues set
      name         = coalesce(s->>'name', name),
      max_managers = coalesce((s->>'max_managers')::int, max_managers),
      roster_size  = coalesce((s->>'roster_size')::int, roster_size),
      max_per_team = case when s ? 'max_per_team' then (s->>'max_per_team')::int else max_per_team end,
      draft_mode   = coalesce(s->>'draft_mode', draft_mode),
      draft_order  = coalesce(s->>'draft_order', draft_order),
      bid_seconds  = coalesce((s->>'bid_seconds')::int, bid_seconds),
      gender       = coalesce(s->>'gender', gender),
      season_start = coalesce((s->>'season_start')::date, season_start)
    where id = p_league;
    if (select count(*) from managers where league_id = p_league) > (select max_managers from leagues where id = p_league) then
      raise exception 'Es sind schon mehr Manager beigetreten.';
    end if;
  elsif s ?| array['max_managers', 'roster_size', 'max_per_team', 'draft_mode', 'draft_order', 'gender', 'season_start', 'bid_seconds'] then
    raise exception 'Diese Einstellung ist nach dem Draft nicht mehr änderbar.';
  end if;
  -- jederzeit änderbar
  update leagues set
    name         = coalesce(s->>'name', name),
    scoring_mode = coalesce(s->>'scoring_mode', scoring_mode),
    lineup_size  = case when s ? 'lineup_size' then (s->>'lineup_size')::int else lineup_size end,
    waiver_mode  = coalesce(s->>'waiver_mode', waiver_mode),
    season_end   = coalesce((s->>'season_end')::date, season_end)
  where id = p_league;
  if (select scoring_mode = 'lineup' and lineup_size is null from leagues where id = p_league) then
    raise exception 'Im Aufstellungsmodus muss die Zahl der wertenden Fahrer gesetzt sein.';
  end if;
  perform _log(p_league, 'settings', s);
end $$;

create or replace function delete_league(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  delete from leagues where id = p_league;
end $$;

-- =====================================================================
-- Live-Auktions-Draft
-- =====================================================================

create or replace function _draft_next(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues; d draft_state; v_rider text; v_cur_pos int; v_next uuid;
        v_n int; v_pick int; v_round int; v_idx int; v_pos int;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;

  if not exists (select 1 from managers m where m.league_id = p_league and _open_slots(m.id) > 0) then
    update draft_state set status = 'done', current_rider = null, current_bid = 0, current_bidder = null,
                           deadline = null, nominator = null, updated_at = now()
     where league_id = p_league;
    update leagues set status = 'active', last_waiver_run = now() where id = p_league;
    return;
  end if;

  if l.draft_mode = 'snake' then
    -- Schlangenreihenfolge: Runde 1 vorwärts, Runde 2 rückwärts, …
    select count(*) into v_n from managers where league_id = p_league;
    v_pick := d.lot_no + 1;
    v_round := (v_pick - 1) / v_n;
    v_idx := (v_pick - 1) % v_n;
    v_pos := case when v_round % 2 = 0 then v_idx + 1 else v_n - v_idx end;
    select id into v_next from managers where league_id = p_league
     order by draft_position, id offset v_pos - 1 limit 1;
    update draft_state set phase = 'snake', lot_no = v_pick, current_rider = null, current_bid = 0, current_bidder = null,
                           nominator = v_next, deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
     where league_id = p_league;
    return;
  end if;

  if d.phase = 'auction' and l.draft_order = 'ranking' then
    select r.pcs_slug into v_rider from riders r
     where r.gender = l.gender and r.uci_rank is not null and not r.inactive
       and not exists (select 1 from draft_lots x where x.league_id = p_league and x.rider_slug = r.pcs_slug)
     order by r.uci_rank, r.pcs_slug limit 1;
    if v_rider is not null then
      update draft_state set lot_no = lot_no + 1, current_rider = v_rider, current_bid = 0, current_bidder = null,
                             deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
       where league_id = p_league;
      return;
    end if;
    update draft_state set phase = 'fill' where league_id = p_league;   -- Rangliste durch
  end if;

  -- Reihum: nächster Manager mit freiem Platz nominiert (bzw. wählt in der Auffüllphase)
  select draft_position into v_cur_pos from managers where id = d.nominator;
  select m.id into v_next from managers m
   where m.league_id = p_league and _open_slots(m.id) > 0
   order by case when m.draft_position > coalesce(v_cur_pos, 0) then 0 else 1 end, m.draft_position
   limit 1;
  update draft_state set current_rider = null, current_bid = 0, current_bidder = null, deadline = null,
                         nominator = v_next, updated_at = now()
   where league_id = p_league;
end $$;

create or replace function start_draft(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  perform _start_draft(p_league);
  perform _log(p_league, 'start_draft', null);
end $$;

-- Geplanten Draft starten, sobald die Zeit erreicht ist (darf jedes Mitglied auslösen)
create or replace function start_scheduled_draft(p_league uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare l leagues;
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' or l.draft_mode = 'offline' or l.draft_at is null or l.draft_at > now() then
    return false;
  end if;
  perform _start_draft(p_league);
  insert into admin_log (league_id, user_id, action, details) values (p_league, null, 'start_draft', '{"geplant": true}');
  return true;
end $$;

create or replace function schedule_draft(p_league uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if (select status from leagues where id = p_league) <> 'setup' then raise exception 'Der Draft wurde schon gestartet.'; end if;
  if p_at is not null and p_at < now() - interval '1 minute' then raise exception 'Der Zeitpunkt liegt in der Vergangenheit.'; end if;
  update leagues set draft_at = p_at where id = p_league;
  perform _log(p_league, 'schedule_draft', jsonb_build_object('at', p_at));
end $$;

create or replace function _start_draft(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues;
begin
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' then raise exception 'Der Draft wurde schon gestartet.'; end if;
  if l.draft_mode = 'offline' then raise exception 'Diese Liga nutzt den Offline-Import.'; end if;
  if (select count(*) from managers where league_id = p_league) < 2 then raise exception 'Mindestens 2 Manager nötig.'; end if;
  if not exists (select 1 from riders where gender = l.gender and uci_rank is not null) then
    raise exception 'Noch keine Fahrer importiert (Workflow "Fahrerliste importieren").';
  end if;

  update managers m set draft_position = s.rn, budget_left = l.budget
    from (select id, row_number() over (order by random()) rn from managers where league_id = p_league) s
   where m.id = s.id;
  insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
  update draft_state set status = 'running', phase = 'auction', lot_no = 0, current_rider = null, current_bid = 0,
                         current_bidder = null, deadline = null, nominator = null, updated_at = now()
   where league_id = p_league;
  update leagues set status = 'drafting' where id = p_league;
  perform _draft_next(p_league);
end $$;

create or replace function pause_draft(p_league uuid, p_pause boolean) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state;
begin
  perform _require_admin(p_league);
  select * into d from draft_state where league_id = p_league for update;
  if p_pause and d.status = 'running' then
    update draft_state set status = 'paused',
           paused_remaining = case when deadline is null then null else greatest(deadline - now(), interval '5 seconds') end,
           deadline = null, updated_at = now()
     where league_id = p_league;
  elsif not p_pause and d.status = 'paused' then
    update draft_state set status = 'running',
           deadline = case when paused_remaining is null then null else now() + paused_remaining end,
           paused_remaining = null, updated_at = now()
     where league_id = p_league;
  end if;
end $$;

create or replace function draft_bid(p_league uuid, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_me uuid; v_max int;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league for update;
  if d.status <> 'running' then raise exception 'Der Draft läuft gerade nicht.'; end if;
  if d.current_rider is null or d.deadline is null or now() >= d.deadline then raise exception 'Gerade wird kein Fahrer versteigert.'; end if;
  if d.current_bidder = v_me then raise exception 'Du bist schon Höchstbietender.'; end if;
  if _open_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll.'; end if;
  if p_amount < greatest(l.min_bid, d.current_bid + 1) then
    raise exception 'Gebot muss mindestens % sein.', greatest(l.min_bid, d.current_bid + 1);
  end if;
  v_max := _max_bid(v_me);
  if p_amount > v_max then raise exception 'Dein Höchstgebot ist %.', v_max; end if;
  if not _team_limit_ok(v_me, d.current_rider) then raise exception 'Du hast schon die Höchstzahl an Fahrern dieses Profiteams.'; end if;

  update draft_state set current_bid = p_amount, current_bidder = v_me,
         deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
   where league_id = p_league;
  insert into draft_bids (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no, v_me, p_amount);
end $$;

-- Wird von allen Clients aufgerufen, wenn die Uhr abläuft. Nur der erste Aufruf wirkt.
create or replace function draft_tick(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues;
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  select * into d from draft_state where league_id = p_league for update;
  if d.status <> 'running' or d.deadline is null or now() < d.deadline then return; end if;
  select * into l from leagues where id = p_league;

  if d.phase = 'snake' then
    perform _snake_pick(p_league, null);
    return;
  end if;

  if d.current_rider is not null then
    if d.current_bid > 0 and d.current_bidder is not null then
      insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
      values (p_league, d.current_bidder, d.current_rider, d.current_bid, 'draft', l.season_start);
      update managers set budget_left = budget_left - d.current_bid where id = d.current_bidder;
      insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
      values (p_league, d.lot_no, d.current_rider, d.current_bidder, d.current_bid);
    else
      insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
      values (p_league, d.lot_no, d.current_rider, null, 0);
    end if;
  end if;
  perform _draft_next(p_league);
end $$;

-- Snake-Draft: Pick ausführen (p_rider null = automatisch bester freier Fahrer nach UCI-Rang)
create or replace function _snake_pick(p_league uuid, p_rider text) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_rider text := p_rider;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;
  if v_rider is null then
    select r.pcs_slug into v_rider from riders r
     where r.gender = l.gender and r.uci_rank is not null and not r.inactive
       and _rider_free(p_league, r.pcs_slug, 'infinity') and _team_limit_ok(d.nominator, r.pcs_slug)
     order by r.uci_rank, r.pcs_slug limit 1;
    if v_rider is null then raise exception 'Kein freier Fahrer mehr verfügbar.'; end if;
  end if;
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
  values (p_league, d.nominator, v_rider, 0, 'draft', l.season_start);
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
  values (p_league, d.lot_no, v_rider, d.nominator, 0)
  on conflict (league_id, rider_slug) do update set manager_id = excluded.manager_id, price = 0, lot_no = excluded.lot_no;
  perform _draft_next(p_league);
end $$;

create or replace function draft_snake_pick(p_league uuid, p_rider text) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; v_me uuid;
begin
  v_me := _require_member(p_league);
  select * into d from draft_state where league_id = p_league for update;
  if d.status <> 'running' or d.phase <> 'snake' then raise exception 'Der Snake-Draft läuft gerade nicht.'; end if;
  if d.nominator is distinct from v_me and not is_admin(p_league) then raise exception 'Du bist nicht an der Reihe.'; end if;
  if not _rider_free(p_league, p_rider, 'infinity') then raise exception 'Dieser Fahrer ist nicht verfügbar.'; end if;
  if not _team_limit_ok(d.nominator, p_rider) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  perform _snake_pick(p_league, p_rider);
end $$;

-- Modus "reihum nominieren": der Nominierende bringt einen Fahrer mit Gebot 1 ein
create or replace function draft_nominate(p_league uuid, p_rider text) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_me uuid;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league for update;
  if d.status <> 'running' or d.phase <> 'auction' or d.current_rider is not null then
    raise exception 'Gerade kann niemand nominieren.';
  end if;
  if d.nominator is distinct from v_me and not is_admin(p_league) then raise exception 'Du bist nicht an der Reihe.'; end if;
  if exists (select 1 from draft_lots where league_id = p_league and rider_slug = p_rider)
     or not _rider_free(p_league, p_rider, 'infinity') then
    raise exception 'Dieser Fahrer ist nicht verfügbar.';
  end if;
  if not _team_limit_ok(d.nominator, p_rider) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  update draft_state set lot_no = lot_no + 1, current_rider = p_rider, current_bid = 1, current_bidder = d.nominator,
         deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
   where league_id = p_league;
  insert into draft_bids (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no + 1, d.nominator, 1);
end $$;

-- Auffüllphase: Restplätze reihum mit freien Fahrern zum Preis 1
create or replace function draft_fill_pick(p_league uuid, p_rider text) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_me uuid;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league for update;
  if d.status <> 'running' or d.phase <> 'fill' or d.nominator is null then raise exception 'Die Auffüllphase läuft nicht.'; end if;
  if d.nominator is distinct from v_me and not is_admin(p_league) then raise exception 'Du bist nicht an der Reihe.'; end if;
  if not _rider_free(p_league, p_rider, 'infinity') then raise exception 'Dieser Fahrer ist nicht verfügbar.'; end if;
  if not _team_limit_ok(d.nominator, p_rider) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
  values (p_league, d.nominator, p_rider, 1, 'draft', l.season_start);
  update managers set budget_left = budget_left - 1 where id = d.nominator;
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
  values (p_league, d.lot_no + 1, p_rider, d.nominator, 1)
  on conflict (league_id, rider_slug) do update set manager_id = excluded.manager_id, price = 1;
  update draft_state set lot_no = lot_no + 1 where league_id = p_league;
  perform _draft_next(p_league);
end $$;

-- =====================================================================
-- Offline-Draft-Import
-- p_rows: [{"manager_id": "...", "rider_slug": "...", "price": 12}, …]
-- Gibt eine Liste von Fehlern zurück; nur ohne Fehler und mit p_commit wird gespeichert.
-- =====================================================================

create or replace function import_offline_draft(p_league uuid, p_rows jsonb, p_commit boolean default false)
returns text[] language plpgsql security definer set search_path = public as $$
declare l leagues; errs text[] := '{}'; r record;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' then return array['Die Kader sind bereits fixiert.']; end if;

  create temp table _imp on commit drop as
    select (e->>'manager_id')::uuid manager_id, e->>'rider_slug' rider_slug,
           coalesce(nullif(e->>'price', '')::int, 0) price
      from jsonb_array_elements(p_rows) e;

  for r in select i.manager_id from _imp i where not exists (select 1 from managers m where m.id = i.manager_id and m.league_id = p_league) group by 1 loop
    errs := errs || format('Unbekannter Manager %s', r.manager_id);
  end loop;
  for r in select i.rider_slug from _imp i where not exists (select 1 from riders x where x.pcs_slug = i.rider_slug and x.gender = l.gender) loop
    errs := errs || format('Fahrer %s nicht im UCI-Ranking gefunden', r.rider_slug);
  end loop;
  for r in select rider_slug from _imp group by 1 having count(*) > 1 loop
    errs := errs || format('Fahrer %s ist mehrfach vergeben', r.rider_slug);
  end loop;
  for r in select m.team_name, count(i.rider_slug) n, coalesce(sum(i.price), 0) s
             from managers m left join _imp i on i.manager_id = m.id
            where m.league_id = p_league group by m.id, m.team_name loop
    if r.n <> l.roster_size then errs := errs || format('%s: %s statt %s Fahrer', r.team_name, r.n, l.roster_size); end if;
    if r.s > l.budget then errs := errs || format('%s: Summe %s über Budget %s', r.team_name, r.s, l.budget); end if;
  end loop;
  for r in select * from _imp where price < 0 loop
    errs := errs || format('Negativer Preis bei %s', r.rider_slug);
  end loop;
  if l.max_per_team is not null then
    for r in select m.team_name, x.team, count(*) n from _imp i join riders x on x.pcs_slug = i.rider_slug
               join managers m on m.id = i.manager_id where x.team is not null
              group by m.team_name, x.team having count(*) > l.max_per_team loop
      errs := errs || format('%s: %s Fahrer von %s (max. %s)', r.team_name, r.n, r.team, l.max_per_team);
    end loop;
  end if;

  if array_length(errs, 1) is null and p_commit then
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
      select p_league, manager_id, rider_slug, price, 'offline', l.season_start from _imp;
    update managers m set budget_left = l.budget - coalesce((select sum(price) from _imp i where i.manager_id = m.id), 0),
           draft_position = s.rn
      from (select id, row_number() over (order by random()) rn from managers where league_id = p_league) s
     where m.id = s.id;
    insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
    update draft_state set status = 'done' where league_id = p_league;
    update leagues set status = 'active', last_waiver_run = now() where id = p_league;
    perform _log(p_league, 'offline_import', jsonb_build_object('rows', jsonb_array_length(p_rows)));
  end if;
  drop table _imp;
  return errs;
end $$;

-- =====================================================================
-- Spieltage
-- =====================================================================

create or replace function upsert_matchday(p_league uuid, p_id uuid, p_name text, p_start date, p_end date,
                                           p_deadline timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; m matchdays; v_deadline timestamptz;
begin
  perform _require_admin(p_league);
  v_deadline := coalesce(p_deadline, p_start::timestamp at time zone 'Europe/Berlin');
  if p_end < p_start then raise exception 'Das Enddatum liegt vor dem Startdatum.'; end if;
  if p_id is null then
    insert into matchdays (league_id, name, starts_on, ends_on, deadline)
    values (p_league, p_name, p_start, p_end, v_deadline) returning id into v;
  else
    select * into m from matchdays where id = p_id and league_id = p_league;
    if not found then raise exception 'Spieltag nicht gefunden.'; end if;
    if m.waivers_done or m.deadline <= now() then raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.'; end if;
    update matchdays set name = p_name, starts_on = p_start, ends_on = p_end, deadline = v_deadline where id = p_id;
    v := p_id;
  end if;
  return v;
exception when exclusion_violation then
  raise exception 'Spieltage dürfen sich nicht überlappen.';
end $$;

create or replace function delete_matchday(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m matchdays;
begin
  select * into m from matchdays where id = p_id;
  if not found then raise exception 'Spieltag nicht gefunden.'; end if;
  perform _require_admin(m.league_id);
  if m.waivers_done or m.deadline <= now() then raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.'; end if;
  delete from matchdays where id = p_id;
end $$;

-- =====================================================================
-- Aufstellung
-- =====================================================================

-- Gültige Aufstellung: letzte gesetzte Aufstellung bis zu diesem Spieltag,
-- sonst die teuersten Fahrer des Kaders.
create or replace function effective_lineup(p_matchday uuid, p_manager uuid) returns setof text
language plpgsql stable security definer set search_path = public as $$
declare md matchdays; l leagues; v_src uuid;
begin
  select * into md from matchdays where id = p_matchday;
  select * into l from leagues where id = md.league_id;
  select lm.id into v_src from matchdays lm
   where lm.league_id = md.league_id and lm.starts_on <= md.starts_on
     and exists (select 1 from lineups x where x.matchday_id = lm.id and x.manager_id = p_manager)
   order by lm.starts_on desc limit 1;
  if v_src is not null then
    return query select x.rider_slug from lineups x where x.matchday_id = v_src and x.manager_id = p_manager;
    return;
  end if;
  return query select re.rider_slug from roster_entries re
    where re.manager_id = p_manager and re.acquired_on <= md.starts_on
      and (re.released_on is null or re.released_on > md.starts_on)
    order by re.price desc, re.id
    limit coalesce(md.lineup_size, l.lineup_size, l.roster_size);
end $$;

create or replace function set_lineup(p_matchday uuid, p_riders text[]) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; l leagues; v_me uuid;
begin
  select * into md from matchdays where id = p_matchday;
  if not found then raise exception 'Spieltag nicht gefunden.'; end if;
  v_me := _require_member(md.league_id);
  select * into l from leagues where id = md.league_id;
  if now() >= md.deadline then raise exception 'Der Stichtag für diesen Spieltag ist vorbei.'; end if;
  if l.scoring_mode <> 'lineup' then raise exception 'Die Liga wertet den Gesamtkader.'; end if;
  if coalesce(array_length(p_riders, 1), 0) <> l.lineup_size then
    raise exception 'Bitte genau % Fahrer aufstellen.', l.lineup_size;
  end if;
  if exists (select 1 from unnest(p_riders) r where not exists (
      select 1 from roster_entries re where re.manager_id = v_me and re.rider_slug = r and re.released_on is null)) then
    raise exception 'Du kannst nur Fahrer aus deinem Kader aufstellen.';
  end if;
  delete from lineups where matchday_id = p_matchday and manager_id = v_me;
  insert into lineups (matchday_id, manager_id, rider_slug) select p_matchday, v_me, unnest(p_riders);
end $$;

-- =====================================================================
-- Punkte und Tabelle
-- =====================================================================

-- Alle Einzelergebnisse, die in der Liga zählen (eingefroren oder live)
create or replace function _score_rows(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, race_slug text, label text,
               result_date date, points numeric)
language sql stable security definer set search_path = public as $$
  select s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, s.label, s.result_date, s.points
    from score_snapshot s join matchdays m on m.id = s.matchday_id
   where m.league_id = p_league and m.frozen
  union all
  select m.id, re.manager_id, re.rider_slug, r.race_slug, r.label, r.result_date, r.uci_points
    from matchdays m
    join leagues l on l.id = m.league_id
    join roster_entries re on re.league_id = m.league_id
    join results r on r.rider_slug = re.rider_slug
                  and r.result_date between m.starts_on and m.ends_on
                  and r.result_date >= re.acquired_on
                  and (re.released_on is null or r.result_date < re.released_on)
   where m.league_id = p_league and not m.frozen and m.starts_on <= current_date
     and (coalesce(m.scoring_mode, l.scoring_mode) = 'full'
          or re.rider_slug in (select effective_lineup(m.id, re.manager_id)));
$$;

-- Punkte pro Spieltag, Manager und Fahrer (inkl. Admin-Korrekturen)
create or replace function _league_points(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, points numeric, overridden boolean)
language sql stable security definer set search_path = public as $$
  with agg as (
    select s.matchday_id, s.manager_id, s.rider_slug, sum(s.points) pts
      from _score_rows(p_league) s group by 1, 2, 3),
  ov as (select * from point_overrides o where o.league_id = p_league)
  select coalesce(a.matchday_id, ov.matchday_id), coalesce(a.manager_id, ov.manager_id),
         coalesce(a.rider_slug, ov.rider_slug), coalesce(ov.points, a.pts), ov.id is not null
    from agg a full join ov on ov.matchday_id = a.matchday_id and ov.manager_id = a.manager_id
                           and ov.rider_slug = a.rider_slug;
$$;

-- Liga-Tabelle mit Tiebreakern: Punkte, Spieltagssiege, bester Spieltag, weniger Budget ausgegeben
create or replace function _league_table(p_league uuid)
returns table (manager_id uuid, team_name text, total numeric, matchday_wins int, best_matchday numeric,
               spent int, "position" int)
language sql stable security definer set search_path = public as $$
  with lp as (select * from _league_points(p_league)),
  md as (select lp.matchday_id, lp.manager_id, sum(lp.points) p from lp group by 1, 2),
  mx as (select md.matchday_id, max(md.p) m from md group by 1),
  w  as (select md.manager_id, count(*)::int n from md join mx on mx.matchday_id = md.matchday_id
          where md.p = mx.m and mx.m > 0 group by 1),
  sp as (select re.manager_id, sum(re.price)::int s from roster_entries re
          where re.league_id = p_league and re.source in ('draft', 'offline') group by 1),
  t as (
    select m.id, m.team_name, coalesce((select sum(md.p) from md where md.manager_id = m.id), 0) tot,
           coalesce(w.n, 0) wins, coalesce((select max(md.p) from md where md.manager_id = m.id), 0) best,
           coalesce(sp.s, 0) spent
      from managers m left join w on w.manager_id = m.id left join sp on sp.manager_id = m.id
     where m.league_id = p_league)
  select t.id, t.team_name, t.tot, t.wins, t.best, t.spent,
         (rank() over (order by t.tot desc, t.wins desc, t.best desc, t.spent asc))::int
    from t order by 7, 2;
$$;

-- Waiver-Reihenfolge: Tabellenletzter zuerst; solange alle 0 Punkte haben, umgekehrte Draft-Reihenfolge
create or replace function _waiver_order(p_league uuid)
returns table (manager_id uuid, team_name text, waiver_pos int)
language sql stable security definer set search_path = public as $$
  with t as (select * from _league_table(p_league)),
  allzero as (select coalesce(bool_and(t.total = 0), true) z from t)
  select t.manager_id, t.team_name,
         (row_number() over (order by case when (select z from allzero) then 0 else t."position" end desc,
                                      m.draft_position desc nulls last))::int
    from t join managers m on m.id = t.manager_id
   order by 3;
$$;

create or replace function league_points(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, points numeric, overridden boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_points(p_league);
end $$;

create or replace function league_table(p_league uuid)
returns table (manager_id uuid, team_name text, total numeric, matchday_wins int, best_matchday numeric,
               spent int, "position" int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_table(p_league);
end $$;

create or replace function waiver_order(p_league uuid)
returns table (manager_id uuid, team_name text, waiver_pos int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _waiver_order(p_league);
end $$;

-- UCI-Punkte pro Fahrer in einem Jahr (für die Fahrerliste der App)
create or replace function rider_points(p_gender text, p_year int)
returns table (rider_slug text, points numeric, results int)
language sql stable security definer set search_path = public as $$
  select r.rider_slug, sum(r.uci_points), count(*)::int
    from results r join riders x on x.pcs_slug = r.rider_slug
   where x.gender = p_gender
     and r.result_date >= make_date(p_year, 1, 1) and r.result_date <= make_date(p_year, 12, 31)
   group by r.rider_slug;
$$;

-- Herkunft der Punkte (einzelne Rennergebnisse)
create or replace function league_point_details(p_league uuid, p_matchday uuid default null)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, race_slug text, race_name text,
               label text, result_date date, points numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  return query
  select s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, rc.name, s.label, s.result_date, s.points
    from _score_rows(p_league) s left join races rc on rc.pcs_slug = s.race_slug
   where p_matchday is null or s.matchday_id = p_matchday
   order by s.result_date desc, s.points desc;
end $$;

-- =====================================================================
-- Waiver
-- =====================================================================

create or replace function submit_waiver(p_league uuid, p_add text, p_drop text, p_bid int default 0,
                                         p_immediate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leagues; v_me uuid; v_id uuid; v_budget int;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  if l.status <> 'active' then raise exception 'Waiver sind erst nach dem Draft möglich.'; end if;
  if not exists (select 1 from roster_entries where manager_id = v_me and rider_slug = p_drop and released_on is null) then
    raise exception 'Der abzugebende Fahrer ist nicht in deinem Kader.';
  end if;
  if not _rider_free(p_league, p_add, 'infinity') then raise exception 'Dieser Fahrer ist nicht frei.'; end if;
  select budget_left into v_budget from managers where id = v_me;
  if l.waiver_mode = 'faab' and (p_bid < 0 or p_bid > v_budget) then
    raise exception 'Gebot muss zwischen 0 und deinem Restbudget (%) liegen.', v_budget;
  end if;

  if p_immediate then
    -- Ersatz außer der Reihe bei Karriereende/Sperre
    if not (select inactive from riders where pcs_slug = p_drop) then
      raise exception 'Sofort-Ersatz nur für Fahrer mit Karriereende oder Sperre.';
    end if;
    if not _rider_free(p_league, p_add, coalesce(l.last_waiver_run, '-infinity')) then
      raise exception 'Dieser Fahrer ist bis zum nächsten Stichtag gesperrt.';
    end if;
    if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
    perform _release(p_league, v_me, p_drop, current_date);
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'waiver', current_date);
    insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, status, note, processed_at)
    values (p_league, v_me, p_add, p_drop, 'won', 'Sofort-Ersatz', now()) returning id into v_id;
    return v_id;
  end if;

  insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, bid, priority)
  values (p_league, v_me, p_add, p_drop, case when l.waiver_mode = 'faab' then p_bid else 0 end,
          coalesce((select max(priority) from waiver_claims where manager_id = v_me and status = 'pending'), 0) + 1)
  returning id into v_id;
  return v_id;
end $$;

create or replace function cancel_waiver(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update waiver_claims c set status = 'cancelled', processed_at = now()
   where c.id = p_id and c.status = 'pending'
     and c.manager_id in (select id from managers where user_id = auth.uid());
end $$;

create or replace function reorder_waivers(p_league uuid, p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid;
begin
  v_me := _require_member(p_league);
  update waiver_claims c set priority = x.ord
    from unnest(p_ids) with ordinality x(id, ord)
   where c.id = x.id and c.manager_id = v_me and c.status = 'pending';
end $$;

create or replace function _claim_valid(c waiver_claims, l leagues) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from roster_entries where manager_id = c.manager_id and rider_slug = c.drop_rider and released_on is null) then
    return 'Abzugebender Fahrer nicht mehr im Kader';
  end if;
  if not _rider_free(l.id, c.add_rider, now()) then return 'Fahrer schon vergeben'; end if;
  if not _team_limit_ok(c.manager_id, c.add_rider, c.drop_rider) then return 'Grenze pro Profiteam'; end if;
  if l.waiver_mode = 'faab' and c.bid > (select budget_left from managers where id = c.manager_id) then
    return 'Restbudget reicht nicht';
  end if;
  return null;
end $$;

create or replace function _execute_claim(c waiver_claims, l leagues, md matchdays) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _release(l.id, c.manager_id, c.drop_rider, md.starts_on);
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
  values (l.id, c.manager_id, c.add_rider, case when l.waiver_mode = 'faab' then c.bid else 0 end, 'waiver', md.starts_on);
  if l.waiver_mode = 'faab' then
    update managers set budget_left = budget_left - c.bid where id = c.manager_id;
  end if;
  update waiver_claims set status = 'won', processed_at = now(), matchday_id = md.id where id = c.id;
  -- andere Anträge mit demselben abzugebenden Fahrer werden ungültig
  update waiver_claims set status = 'lost', note = 'Abzugebender Fahrer schon getauscht', processed_at = now(), matchday_id = md.id
   where manager_id = c.manager_id and status = 'pending' and drop_rider = c.drop_rider;
end $$;

create or replace function _process_waivers(p_md uuid) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; l leagues; v_order uuid[]; v_mgr uuid; c waiver_claims; v_why text;
        v_success boolean; v_best waiver_claims; v_best_idx int; i int;
begin
  select * into md from matchdays where id = p_md;
  select * into l from leagues where id = md.league_id;
  select array_agg(w.manager_id order by w.waiver_pos) into v_order from _waiver_order(l.id) w;

  loop
    v_success := false;
    v_best := null; v_best_idx := null;
    for i in 1 .. coalesce(array_length(v_order, 1), 0) loop
      v_mgr := v_order[i];
      -- obersten gültigen Antrag dieses Managers suchen
      c := null;
      for c in select * from waiver_claims
                where manager_id = v_mgr and status = 'pending' and created_at <= md.deadline
                order by priority, created_at loop
        v_why := _claim_valid(c, l);
        if v_why is null then exit; end if;
        update waiver_claims set status = 'lost', note = v_why, processed_at = now(), matchday_id = md.id where id = c.id;
        c := null;
      end loop;
      if c.id is null then continue; end if;

      if l.waiver_mode = 'priority' then
        perform _execute_claim(c, l, md);       -- ein Zuschlag pro Runde und Manager
        v_success := true;
      elsif v_best.id is null or c.bid > v_best.bid then
        v_best := c; v_best_idx := i;           -- FAAB: Höchstgebot, bei Gleichstand der schlechter Platzierte
      end if;
    end loop;

    if l.waiver_mode = 'faab' and v_best.id is not null then
      perform _execute_claim(v_best, l, md);
      v_success := true;
    end if;
    exit when not v_success;
  end loop;
end $$;

-- =====================================================================
-- Tausch zwischen Managern
-- =====================================================================

create or replace function propose_trade(p_league uuid, p_to uuid, p_give text[], p_take text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v_me uuid; v uuid;
begin
  v_me := _require_member(p_league);
  if (select status from leagues where id = p_league) <> 'active' then raise exception 'Tausch erst nach dem Draft.'; end if;
  if p_to = v_me or not exists (select 1 from managers where id = p_to and league_id = p_league) then
    raise exception 'Ungültiger Tauschpartner.';
  end if;
  if coalesce(array_length(p_give, 1), 0) = 0 or coalesce(array_length(p_give, 1), 0) <> coalesce(array_length(p_take, 1), 0) then
    raise exception 'Beide Seiten müssen gleich viele Fahrer abgeben (mindestens 1).';
  end if;
  if (select count(*) from roster_entries where manager_id = v_me and released_on is null and rider_slug = any (p_give)) <> array_length(p_give, 1)
     or (select count(*) from roster_entries where manager_id = p_to and released_on is null and rider_slug = any (p_take)) <> array_length(p_take, 1) then
    raise exception 'Die Fahrer müssen in den jeweiligen Kadern stehen.';
  end if;
  insert into trades (league_id, from_manager, to_manager, give_riders, take_riders)
  values (p_league, v_me, p_to, p_give, p_take) returning id into v;
  return v;
end $$;

create or replace function respond_trade(p_trade uuid, p_accept boolean) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if not found or t.status <> 'proposed' then raise exception 'Kein offenes Angebot.'; end if;
  if t.to_manager <> my_manager(t.league_id) then raise exception 'Dieses Angebot ist nicht an dich.'; end if;
  update trades set status = case when p_accept then 'accepted' else 'declined' end,
                    accepted_at = case when p_accept then now() end
   where id = p_trade;
end $$;

create or replace function cancel_trade(p_trade uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if t.from_manager <> my_manager(t.league_id) then raise exception 'Nicht dein Angebot.'; end if;
  update trades set status = 'cancelled' where id = p_trade and status in ('proposed', 'accepted');
end $$;

create or replace function veto_trade(p_trade uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  perform _require_admin(t.league_id);
  if t.status <> 'accepted' or now() > t.accepted_at + interval '24 hours' then
    raise exception 'Veto nur innerhalb von 24 Stunden nach Zustimmung.';
  end if;
  update trades set status = 'vetoed' where id = p_trade;
  perform _log(t.league_id, 'veto_trade', jsonb_build_object('trade', p_trade));
end $$;

-- Angenommene Tauschs werden zum nächsten Stichtag nach Ablauf der Vetofrist ausgeführt
create or replace function _process_trades(p_md uuid) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; t trades; r text;
begin
  select * into md from matchdays where id = p_md;
  for t in select * from trades where league_id = md.league_id and status = 'accepted'
                                  and accepted_at + interval '24 hours' <= md.deadline order by accepted_at loop
    if (select count(*) from roster_entries where manager_id = t.from_manager and released_on is null and rider_slug = any (t.give_riders)) <> array_length(t.give_riders, 1)
       or (select count(*) from roster_entries where manager_id = t.to_manager and released_on is null and rider_slug = any (t.take_riders)) <> array_length(t.take_riders, 1) then
      update trades set status = 'failed', note = 'Fahrer nicht mehr im Kader', done_at = now() where id = t.id;
      continue;
    end if;
    foreach r in array t.give_riders loop
      perform _release(md.league_id, t.from_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, rider_slug, source, acquired_on) values (md.league_id, t.to_manager, r, 'trade', md.starts_on);
    end loop;
    foreach r in array t.take_riders loop
      perform _release(md.league_id, t.to_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, rider_slug, source, acquired_on) values (md.league_id, t.from_manager, r, 'trade', md.starts_on);
    end loop;
    update trades set status = 'done', done_at = now() where id = t.id;
  end loop;
end $$;

-- =====================================================================
-- Stichtage und Spieltags-Status
-- =====================================================================

-- Arbeitet alle fälligen Stichtage ab (Tausch, Waiver, Wertungsmodus übernehmen).
-- Darf jeder angemeldete Nutzer aufrufen; die App tut das beim Öffnen.
create or replace function process_due(p_league uuid default null) returns int
language plpgsql security definer set search_path = public as $$
declare md matchdays; n int := 0;
begin
  for md in select m.* from matchdays m join leagues l on l.id = m.league_id
             where not m.waivers_done and m.deadline <= now() and l.status = 'active'
               and (p_league is null or m.league_id = p_league)
             order by m.deadline
             for update of m skip locked loop
    update matchdays m set scoring_mode = l.scoring_mode, lineup_size = l.lineup_size
      from leagues l where l.id = m.league_id and m.id = md.id;
    perform _process_trades(md.id);
    perform _process_waivers(md.id);
    update matchdays set waivers_done = true where id = md.id;
    update leagues set last_waiver_run = now() where id = md.league_id;
    n := n + 1;
  end loop;
  update matchdays set status = 'running'
   where status = 'planned' and starts_on <= current_date and (p_league is null or league_id = p_league);
  return n;
end $$;

-- Täglich nach dem Ergebnisabruf (nur Service-Key): Spieltage abschließen und
-- 7 Tage nach Abschluss einfrieren.
create or replace function run_maintenance() returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays;
begin
  perform process_due(null);
  update matchdays set status = 'closed', closed_at = now() where status = 'running' and ends_on < current_date;
  for md in select * from matchdays where status = 'closed' and not frozen and closed_at <= now() - interval '7 days' loop
    insert into score_snapshot (league_id, matchday_id, manager_id, rider_slug, race_slug, label, result_date, points)
      select md.league_id, s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, s.label, s.result_date, s.points
        from _score_rows(md.league_id) s where s.matchday_id = md.id;
    update matchdays set frozen = true where id = md.id;
  end loop;
  update leagues set status = 'finished' where status = 'active' and season_end < current_date;
  update sync_status set last_run = now(), ok = true, message = null where id = 1;
end $$;

-- =====================================================================
-- Admin-Werkzeuge
-- =====================================================================

create or replace function admin_set_override(p_league uuid, p_matchday uuid, p_manager uuid, p_rider text,
                                              p_points numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Bitte einen Grund angeben.'; end if;
  if p_points is null then
    delete from point_overrides where matchday_id = p_matchday and manager_id = p_manager and rider_slug = p_rider;
  else
    insert into point_overrides (league_id, matchday_id, manager_id, rider_slug, points, reason, created_by)
    values (p_league, p_matchday, p_manager, p_rider, p_points, p_reason, auth.uid())
    on conflict (matchday_id, manager_id, rider_slug)
    do update set points = excluded.points, reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  end if;
  perform _log(p_league, 'override', jsonb_build_object('matchday', p_matchday, 'manager', p_manager,
               'rider', p_rider, 'points', p_points, 'reason', p_reason));
end $$;

-- Kader korrigieren (sofort wirksam, wird protokolliert)
create or replace function admin_roster_fix(p_league uuid, p_manager uuid, p_add text, p_drop text,
                                            p_price int default 0, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if p_drop is not null and not _release(p_league, p_manager, p_drop, current_date) then
    raise exception 'Fahrer % ist nicht im Kader.', p_drop;
  end if;
  if p_add is not null then
    if not _rider_free(p_league, p_add, 'infinity') then raise exception 'Fahrer % ist nicht frei.', p_add; end if;
    if _open_slots(p_manager) <= 0 then raise exception 'Der Kader ist voll.'; end if;
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, p_manager, p_add, coalesce(p_price, 0), 'admin', current_date);
  end if;
  perform _log(p_league, 'roster_fix', jsonb_build_object('manager', p_manager, 'add', p_add, 'drop', p_drop, 'reason', p_reason));
end $$;

create or replace function admin_mark_inactive(p_league uuid, p_rider text, p_inactive boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  update riders set inactive = p_inactive where pcs_slug = p_rider;
  perform _log(p_league, 'mark_inactive', jsonb_build_object('rider', p_rider, 'inactive', p_inactive));
end $$;

-- =====================================================================
-- Rechte
-- =====================================================================

alter table riders          enable row level security;
alter table races           enable row level security;
alter table results         enable row level security;
alter table sync_status     enable row level security;
alter table leagues         enable row level security;
alter table managers        enable row level security;
alter table draft_state     enable row level security;
alter table draft_lots      enable row level security;
alter table draft_bids      enable row level security;
alter table roster_entries  enable row level security;
alter table matchdays       enable row level security;
alter table lineups         enable row level security;
alter table waiver_claims   enable row level security;
alter table trades          enable row level security;
alter table point_overrides enable row level security;
alter table score_snapshot  enable row level security;
alter table admin_log       enable row level security;
alter table race_events     enable row level security;
alter table event_results   enable row level security;

do $$
declare t text;
begin
  -- öffentliche Stammdaten: lesbar für angemeldete Nutzer
  foreach t in array array['riders', 'races', 'results', 'sync_status', 'race_events', 'event_results'] loop
    execute format('drop policy if exists read_all on %I', t);
    execute format('create policy read_all on %I for select to authenticated using (true)', t);
  end loop;
  -- Ligadaten: nur für Mitglieder
  foreach t in array array['managers', 'draft_state', 'draft_lots', 'draft_bids', 'roster_entries',
                           'matchdays', 'trades', 'point_overrides', 'score_snapshot', 'admin_log'] loop
    execute format('drop policy if exists members_read on %I', t);
    execute format('create policy members_read on %I for select to authenticated using (is_member(league_id))', t);
  end loop;
end $$;

drop policy if exists members_read on leagues;
create policy members_read on leagues for select to authenticated using (is_member(id));

drop policy if exists members_read on lineups;
create policy members_read on lineups for select to authenticated
  using (exists (select 1 from matchdays m where m.id = matchday_id and is_member(m.league_id)));

-- Waiver-Anträge: eigene immer, fremde erst nach Abwicklung (Gebote bleiben verdeckt)
drop policy if exists members_read on waiver_claims;
create policy members_read on waiver_claims for select to authenticated
  using (is_member(league_id) and (status <> 'pending' or manager_id = my_manager(league_id)));

-- interne Funktionen nicht direkt aufrufbar
do $$
declare f text;
begin
  foreach f in array array[
    '_require_member(uuid)', '_require_admin(uuid)', '_log(uuid,text,jsonb)', '_open_slots(uuid)',
    '_max_bid(uuid)', '_team_limit_ok(uuid,text,text)', '_rider_free(uuid,text,timestamptz)',
    '_release(uuid,uuid,text,date)', '_draft_next(uuid)', '_start_draft(uuid)', '_snake_pick(uuid,text)', '_score_rows(uuid)',
    '_claim_valid(waiver_claims,leagues)', '_execute_claim(waiver_claims,leagues,matchdays)',
    '_process_waivers(uuid)', '_process_trades(uuid)', '_league_points(uuid)', '_league_table(uuid)',
    '_waiver_order(uuid)', 'run_maintenance()'] loop
    execute format('revoke execute on function %s from public', f);
    begin
      execute format('revoke execute on function %s from anon, authenticated', f);
    exception when undefined_object then null;  -- Rollen gibt es nur in Supabase
    end;
  end loop;
end $$;

-- Live-Updates im Draft-Raum
do $$
begin
  alter publication supabase_realtime add table draft_state;
exception when duplicate_object or undefined_object then null;
end $$;
