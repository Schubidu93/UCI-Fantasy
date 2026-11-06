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

-- Benachrichtigung an den Nutzer hinter einem Manager (Platzhalter ohne Konto werden übersprungen)
create or replace function _notify(p_manager uuid, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, title, body, url)
  select user_id, p_title, p_body, p_url from managers where id = p_manager and user_id is not null
    and exists (select 1 from push_subscriptions s where s.user_id = managers.user_id);
$$;

-- „Du bist dran“ im Draft: sofort senden (Ablauf direkt anstoßen), verfällt mit der Pick-Uhr
create or replace function _notify_turn(p_league uuid, p_manager uuid, p_prev uuid, p_text text, p_expires timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_manager is null or p_manager is not distinct from p_prev then return; end if;   -- gleicher Manager wie eben
  insert into notifications (user_id, title, body, url, expires_at)
  select m.user_id, '⏰ Du bist dran!', l.name || ': ' || p_text, '#/league/' || p_league || '/draft', p_expires
    from managers m join leagues l on l.id = m.league_id
   where m.id = p_manager and m.user_id is not null
     and exists (select 1 from push_subscriptions s where s.user_id = m.user_id);
  if found then
    begin
      perform dispatch_workflow('push.yml');
    exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
    end;
  end if;
end $$;

create or replace function _rname(p_slug text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from riders where pcs_slug = p_slug), p_slug);
$$;

create or replace function vapid_public_key() returns text
language sql stable security definer set search_path = public as $$
  select value from app_config where key = 'vapid_public';
$$;

create or replace function save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function delete_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

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
                       draft_mode, draft_order, bid_seconds, waiver_mode, gender, season_start, season_end, transfer_mode)
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
          coalesce((s->>'season_end')::date, make_date(extract(year from current_date)::int + 1, 10, 31)),
          coalesce(s->>'transfer_mode', 'waiver_free'))
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
    transfer_mode = coalesce(s->>'transfer_mode', transfer_mode),
    season_end   = coalesce((s->>'season_end')::date, season_end)
  where id = p_league;
  -- Transfermodus geändert: künftige Spieltage mit Standard-Fristen neu berechnen
  if s ? 'transfer_mode' and s->>'transfer_mode' is distinct from l.transfer_mode then
    perform _reset_default_deadlines(p_league, l.transfer_mode);
  end if;
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
-- Neue Saison: Liga kopieren und Keeper
-- =====================================================================

create or replace function copy_league(p_league uuid, p_name text, p_season_start date, p_season_end date,
                                       p_keeper_count int default 0, p_keeper_surcharge int default 5)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leagues; v uuid;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league;
  insert into leagues (name, admin_user, max_managers, roster_size, scoring_mode, lineup_size, max_per_team, draft_mode,
                       draft_order, bid_seconds, waiver_mode, gender, season_start, season_end, prev_league,
                       keeper_count, keeper_surcharge)
  values (coalesce(nullif(trim(p_name), ''), l.name), l.admin_user, l.max_managers, l.roster_size, l.scoring_mode,
          l.lineup_size, l.max_per_team, l.draft_mode, l.draft_order, l.bid_seconds, l.waiver_mode, l.gender,
          p_season_start, p_season_end, p_league, coalesce(p_keeper_count, 0), coalesce(p_keeper_surcharge, 5))
  returning id into v;
  insert into managers (league_id, user_id, team_name, prev_manager)
    select v, user_id, team_name, id from managers where league_id = p_league order by draft_position nulls last, joined_at;
  insert into draft_state (league_id) values (v);
  perform _log(p_league, 'copy_league', jsonb_build_object('new_league', v));
  return v;
end $$;

-- Mögliche Keeper des aufrufenden Managers: sein Kader am Ende der Vorsaison
create or replace function keeper_options(p_league uuid)
returns table (rider_slug text, prev_price int, price int, chosen boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid; l leagues;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  return query
  select re.rider_slug, re.price, greatest(1, re.price + l.keeper_surcharge),
         exists (select 1 from keepers k where k.manager_id = v_me and k.rider_slug = re.rider_slug)
    from managers m join roster_entries re on re.manager_id = m.prev_manager and re.released_on is null
   where m.id = v_me
   order by re.price desc;
end $$;

create or replace function set_keepers(p_league uuid, p_riders text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid; l leagues; v_sum int; v_n int := coalesce(array_length(p_riders, 1), 0);
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  if l.status <> 'setup' then raise exception 'Keeper können nur vor dem Draft gewählt werden.'; end if;
  if v_n > l.keeper_count then raise exception 'Du darfst höchstens % Keeper wählen.', l.keeper_count; end if;
  if exists (select 1 from unnest(p_riders) r where r not in (select o.rider_slug from keeper_options(p_league) o)) then
    raise exception 'Nur Fahrer aus deinem Vorjahreskader.';
  end if;
  select coalesce(sum(o.price), 0) into v_sum from keeper_options(p_league) o where o.rider_slug = any (p_riders);
  if l.draft_mode = 'live' and v_sum > l.budget - (l.roster_size - v_n) then
    raise exception 'Zu teuer: Keeper kosten %, es muss Budget für die restlichen Plätze bleiben.', v_sum;
  end if;
  delete from keepers where manager_id = v_me;
  insert into keepers (league_id, manager_id, rider_slug, price)
    select p_league, v_me, o.rider_slug, o.price from keeper_options(p_league) o where o.rider_slug = any (p_riders);
exception when unique_violation then
  raise exception 'Dieser Fahrer ist schon Keeper eines anderen Managers.';
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
    perform _notify(m.id, '🏁 Draft beendet!', l.name || ': Dein Draft-Report mit Note ist da.', '#/league/' || p_league || '/draft')
       from managers m where m.league_id = p_league;
    return;
  end if;

  if l.draft_mode = 'snake' then
    -- Schlangenreihenfolge: Runde 1 vorwärts, Runde 2 rückwärts, …
    select count(*) into v_n from managers where league_id = p_league;
    v_pick := d.lot_no;
    loop
      v_pick := v_pick + 1;
      v_round := (v_pick - 1) / v_n;
      v_idx := (v_pick - 1) % v_n;
      v_pos := case when v_round % 2 = 0 then v_idx + 1 else v_n - v_idx end;
      select id into v_next from managers where league_id = p_league
       order by draft_position, id offset v_pos - 1 limit 1;
      exit when _open_slots(v_next) > 0;      -- Manager mit vollem Kader (Keeper) überspringen
    end loop;
    update draft_state set phase = 'snake', lot_no = v_pick, current_rider = null, current_bid = 0, current_bidder = null,
                           nominator = v_next, deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
     where league_id = p_league;
    perform _notify_turn(p_league, v_next, d.nominator, 'Dein Pick (Nr. ' || v_pick || ') – du hast ' || l.bid_seconds || ' Sekunden.',
                         now() + make_interval(secs => l.bid_seconds));
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
  perform _notify_turn(p_league, v_next, d.nominator,
    case when d.phase = 'fill' or (d.phase = 'auction' and l.draft_order = 'ranking') then 'Wähle einen Fahrer zum Auffüllen.'
         else 'Du nominierst den nächsten Fahrer.' end, null);
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
  -- Keeper vorab in die Kader (zählen wie gekauft; die Auktion überspringt sie)
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    select p_league, k.manager_id, k.rider_slug, k.price, 'draft', l.season_start from keepers k where k.league_id = p_league;
  update managers m set budget_left = budget_left - coalesce((select sum(price) from keepers k where k.manager_id = m.id), 0)
   where m.league_id = p_league;
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
    select p_league, 0, k.rider_slug, k.manager_id, k.price from keepers k where k.league_id = p_league
  on conflict (league_id, rider_slug) do nothing;
  insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
  update draft_state set status = 'running', phase = 'auction', lot_no = 0, current_rider = null, current_bid = 0,
                         current_bidder = null, deadline = null, nominator = null, updated_at = now()
   where league_id = p_league;
  update leagues set status = 'drafting' where id = p_league;
  perform _draft_next(p_league);
  perform _notify(m.id, '🚴 Der Draft startet jetzt!', l.name || ': Ab in den Draft-Raum.', '#/league/' || p_league || '/draft')
     from managers m where m.league_id = p_league;
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

-- Standard-Stichtag (Kader und Aufstellung fest):
--   nur Waiver:          Vortag des Spieltags, 20:00 Uhr
--   Waiver + frei:       Spieltagstart, 00:00 Uhr
create or replace function _default_deadline(p_league uuid, p_start date) returns timestamptz
language sql stable security definer set search_path = public as $$
  select case when (select transfer_mode from leagues where id = p_league) = 'waiver_free'
              then p_start::timestamp at time zone 'Europe/Berlin'
              else (p_start - 1 + time '20:00')::timestamp at time zone 'Europe/Berlin' end;
$$;

-- Standard-Waiver-Auswertung im zweiteiligen Modus: Ende des 7. Tags vor Start (0:00 Uhr des 6. Tags vor Start).
-- Ist der vorige Spieltag kürzer als 14 Tage: nach der Hälfte seiner Dauer. Nie vor dem vorigen Stichtag.
create or replace function _default_waiver_deadline(p_league uuid, p_start date, p_except uuid default null) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
declare prev matchdays; v timestamptz; v_lock timestamptz := _default_deadline(p_league, p_start);
begin
  if (select transfer_mode from leagues where id = p_league) <> 'waiver_free' then return null; end if;
  select * into prev from matchdays where league_id = p_league and starts_on < p_start
     and id is distinct from p_except order by starts_on desc limit 1;
  if found and prev.ends_on - prev.starts_on + 1 < 14 then
    v := (prev.starts_on + (prev.ends_on - prev.starts_on + 1) / 2 + 1)::timestamp at time zone 'Europe/Berlin';
  else
    v := (p_start - 6)::timestamp at time zone 'Europe/Berlin';
  end if;
  if prev.id is not null and v <= prev.deadline then
    v := (((prev.deadline + (v_lock - prev.deadline) / 2) at time zone 'Europe/Berlin')::date + 1)
         ::timestamp at time zone 'Europe/Berlin';
    if v <= prev.deadline or v >= v_lock then v := prev.deadline + (v_lock - prev.deadline) / 2; end if;
  end if;
  return least(v, v_lock);
end $$;

-- alte Signatur ohne Waiver-Frist entfernen (sonst ist der Aufruf mehrdeutig)
drop function if exists upsert_matchday(uuid, uuid, text, date, date, timestamptz);
create or replace function upsert_matchday(p_league uuid, p_id uuid, p_name text, p_start date, p_end date,
                                           p_deadline timestamptz default null, p_waiver_deadline timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; m matchdays; v_deadline timestamptz; v_wd timestamptz;
begin
  perform _require_admin(p_league);
  v_deadline := coalesce(p_deadline, _default_deadline(p_league, p_start));
  v_wd := coalesce(p_waiver_deadline, _default_waiver_deadline(p_league, p_start, p_id));
  if v_wd > v_deadline then raise exception 'Die Waiver-Auswertung muss vor dem Stichtag liegen.'; end if;
  if p_end < p_start then raise exception 'Das Enddatum liegt vor dem Startdatum.'; end if;
  if p_id is null then
    insert into matchdays (league_id, name, starts_on, ends_on, deadline, waiver_deadline)
    values (p_league, p_name, p_start, p_end, v_deadline, v_wd) returning id into v;
  else
    select * into m from matchdays where id = p_id and league_id = p_league;
    if not found then raise exception 'Spieltag nicht gefunden.'; end if;
    if m.waivers_done or coalesce(m.waiver_deadline, m.deadline) <= now() then
      raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.';
    end if;
    update matchdays set name = p_name, starts_on = p_start, ends_on = p_end, deadline = v_deadline, waiver_deadline = v_wd
     where id = p_id;
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
  if m.waivers_done or coalesce(m.waiver_deadline, m.deadline) <= now() then
    raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.';
  end if;
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

-- Namen vergleichbar machen: 'POGAČAR Tadej' = 'Tadej Pogacar' (Akzente weg, Wörter sortiert)
create extension if not exists unaccent with schema extensions;
create or replace function norm_name(p text) returns text
language sql immutable parallel safe set search_path = public, extensions as $$
  select array_to_string(array(select w from unnest(regexp_split_to_array(
           lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(p, ''))), '[^a-z0-9]+')) w
         where w <> '' order by w), ' ');
$$;
create index if not exists riders_norm_name on riders (gender, norm_name(name));

-- Ergebniszeilen ohne Fahrer-Verknüpfung über den Namen zuordnen (nach Fahrer- oder Rennimport)
-- Punkte aus den Ergebnislisten in die Wertung übernehmen, die dort noch fehlen
-- (z. B. weil der Fahrername erst später einem Fahrer zugeordnet werden konnte).
-- Bezeichnung wie in race_results.py: „Etappe · Wertung“ bzw. nur eins davon.
create or replace function results_from_events() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into results (rider_slug, race_slug, label, result_date, rank, uci_points)
  select er.rider_slug, e.race_slug,
         left(coalesce(nullif(case
           when coalesce(trim(e.stage_name), '') = '' or trim(e.stage_name) = trim(e.event_name) then trim(e.event_name)
           when coalesce(trim(e.event_name), '') = '' then trim(e.stage_name)
           else trim(e.stage_name) || ' · ' || trim(e.event_name) end, ''), 'Ergebnis'), 200),
         e.event_date, er.rank, er.uci_points
    from event_results er join race_events e on e.id = er.event_id
   where er.rider_slug is not null and er.uci_points > 0 and e.event_date >= date '2025-01-01'
     and exists (select 1 from riders x where x.pcs_slug = er.rider_slug)
     -- nicht doppelt zählen: gleiches Ergebnis (Fahrer, Tag, Punkte) schon unter anderem Namen gespeichert
     and not exists (select 1 from results r where r.rider_slug = er.rider_slug and r.result_date = e.event_date
                       and r.uci_points = er.uci_points)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function relink_event_riders() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update event_results er set rider_slug = x.pcs_slug
    from race_events ev join races ra on ra.pcs_slug = ev.race_slug, riders x
   where er.event_id = ev.id and er.rider_slug is null
     and x.gender = ra.gender and norm_name(x.name) = norm_name(er.rider_name);
  get diagnostics n = row_count;
  return n;
end $$;

-- UCI-Punkte pro Fahrer in einem Jahr (für die Fahrerliste der App)
create or replace function rider_points(p_gender text, p_year int)
returns table (rider_slug text, points numeric, results int)
language sql stable security definer set search_path = public as $$
  select r.rider_slug, sum(r.uci_points), count(*)::int
    from results r join riders x on x.pcs_slug = r.rider_slug
   where x.gender = p_gender
     and r.result_date >= make_date(p_year, 1, 1) and r.result_date <= make_date(p_year, 12, 31)
   group by r.rider_slug
   order by r.rider_slug;
$$;

-- ---- Vorläufiger WorldTour-Kalender 2027 ---------------------------------------------------
-- Die UCI trägt die nächste Saison erst nach und nach in DataRide ein. Bis dahin stehen hier die
-- bereits veröffentlichten WorldTour-Termine (Quelle: UCI-Kalender, Presseberichte Okt. 2026).
-- race_results.py ersetzt sie automatisch, sobald DataRide das Rennen liefert.
alter table races add column if not exists provisional boolean not null default false;
insert into races (pcs_slug, name, gender, uci_class, country, start_date, end_date, provisional)
select v.slug, v.name, v.gender, v.cls, v.country, v.s::date, v.e::date, true from (values
  ('santos-tour-down-under/2027', 'Santos Tour Down Under', 'men', '2.UWT', 'AUS', '2027-01-19', '2027-01-24'),
  ('cadel-evans-great-ocean-road-race/2027', 'Cadel Evans Great Ocean Road Race', 'men', '1.UWT', 'AUS', '2027-01-31', '2027-01-31'),
  ('uae-tour/2027', 'UAE Tour', 'men', '2.UWT', 'UAE', '2027-02-15', '2027-02-21'),
  ('omloop-het-nieuwsblad/2027', 'Omloop Het Nieuwsblad', 'men', '1.UWT', 'BEL', '2027-02-27', '2027-02-27'),
  ('strade-bianche/2027', 'Strade Bianche', 'men', '1.UWT', 'ITA', '2027-03-06', '2027-03-06'),
  ('paris-nice/2027', 'Paris-Nice', 'men', '2.UWT', 'FRA', '2027-03-07', '2027-03-14'),
  ('tirreno-adriatico/2027', 'Tirreno-Adriatico', 'men', '2.UWT', 'ITA', '2027-03-08', '2027-03-14'),
  ('milano-sanremo/2027', 'Milano-Sanremo', 'men', '1.UWT', 'ITA', '2027-03-20', '2027-03-20'),
  ('volta-ciclista-a-catalunya/2027', 'Volta Ciclista a Catalunya', 'men', '2.UWT', 'ESP', '2027-03-22', '2027-03-28'),
  ('ronde-van-brugge/2027', 'Ronde van Brugge', 'men', '1.UWT', 'BEL', '2027-03-24', '2027-03-24'),
  ('e3-saxo-classic/2027', 'E3 Saxo Classic', 'men', '1.UWT', 'BEL', '2027-03-26', '2027-03-26'),
  ('in-flanders-fields-gent-wevelgem/2027', 'In Flanders Fields (Gent-Wevelgem)', 'men', '1.UWT', 'BEL', '2027-03-28', '2027-03-28'),
  ('ronde-van-vlaanderen/2027', 'Ronde van Vlaanderen', 'men', '1.UWT', 'BEL', '2027-04-04', '2027-04-04'),
  ('itzulia-basque-country/2027', 'Itzulia Basque Country', 'men', '2.UWT', 'ESP', '2027-04-05', '2027-04-10'),
  ('paris-roubaix/2027', 'Paris-Roubaix', 'men', '1.UWT', 'FRA', '2027-04-11', '2027-04-11'),
  ('amstel-gold-race/2027', 'Amstel Gold Race', 'men', '1.UWT', 'NED', '2027-04-18', '2027-04-18'),
  ('la-fleche-wallonne/2027', 'La Flèche Wallonne', 'men', '1.UWT', 'BEL', '2027-04-21', '2027-04-21'),
  ('liege-bastogne-liege/2027', 'Liège-Bastogne-Liège', 'men', '1.UWT', 'BEL', '2027-04-25', '2027-04-25'),
  ('tour-de-romandie/2027', 'Tour de Romandie', 'men', '2.UWT', 'SUI', '2027-04-27', '2027-05-02'),
  ('eschborn-frankfurt/2027', 'Eschborn-Frankfurt', 'men', '1.UWT', 'GER', '2027-05-02', '2027-05-02'),
  ('giro-d-italia/2027', 'Giro d''Italia', 'men', '2.UWT', 'ITA', '2027-05-08', '2027-05-30'),
  ('tour-auvergne-rhone-alpes/2027', 'Tour Auvergne-Rhône-Alpes', 'men', '2.UWT', 'FRA', '2027-06-06', '2027-06-13'),
  ('copenhagen-sprint/2027', 'Copenhagen Sprint', 'men', '1.UWT', 'DEN', '2027-06-13', '2027-06-13'),
  ('tour-de-suisse/2027', 'Tour de Suisse', 'men', '2.UWT', 'SUI', '2027-06-16', '2027-06-20'),
  ('tour-de-france/2027', 'Tour de France', 'men', '2.UWT', 'FRA', '2027-07-02', '2027-07-25'),
  ('clasica-san-sebastian/2027', 'Clásica San Sebastián', 'men', '1.UWT', 'ESP', '2027-07-31', '2027-07-31'),
  ('tour-de-pologne/2027', 'Tour de Pologne', 'men', '2.UWT', 'POL', '2027-08-02', '2027-08-08'),
  ('adac-cyclassics/2027', 'ADAC Cyclassics', 'men', '1.UWT', 'GER', '2027-08-15', '2027-08-15'),
  ('uci-road-world-championships/2027', 'UCI Road World Championships', 'men', 'CM', 'FRA', '2027-08-24', '2027-09-05'),
  ('la-vuelta-ciclista-a-espana/2027', 'La Vuelta Ciclista a España', 'men', '2.UWT', 'ESP', '2027-09-04', '2027-09-26'),
  ('grand-prix-cycliste-de-quebec/2027', 'Grand Prix Cycliste de Québec', 'men', '1.UWT', 'CAN', '2027-09-10', '2027-09-10'),
  ('grand-prix-cycliste-de-montreal/2027', 'Grand Prix Cycliste de Montréal', 'men', '1.UWT', 'CAN', '2027-09-12', '2027-09-12'),
  ('il-lombardia/2027', 'Il Lombardia', 'men', '1.UWT', 'ITA', '2027-10-09', '2027-10-09'),
  ('tour-of-guangxi/2027', 'Tour of Guangxi', 'men', '2.UWT', 'CHN', '2027-10-12', '2027-10-17'),
  ('santos-tour-down-under/2027/w', 'Santos Tour Down Under', 'women', '2.WWT', 'AUS', '2027-01-22', '2027-01-24'),
  ('strade-bianche-donne/2027/w', 'Strade Bianche Donne', 'women', '1.WWT', 'ITA', '2027-03-06', '2027-03-06'),
  ('liege-bastogne-liege-femmes/2027/w', 'Liège-Bastogne-Liège Femmes', 'women', '1.WWT', 'BEL', '2027-04-25', '2027-04-25'),
  ('vuelta-a-burgos-feminas/2027/w', 'Vuelta a Burgos Feminas', 'women', '2.WWT', 'ESP', '2027-05-06', '2027-05-10'),
  ('giro-d-italia-women/2027/w', 'Giro d''Italia Women', 'women', '2.WWT', 'ITA', '2027-05-29', '2027-06-06'),
  ('copenhagen-sprint/2027/w', 'Copenhagen Sprint', 'women', '1.WWT', 'DEN', '2027-06-12', '2027-06-12'),
  ('tour-de-france-femmes/2027/w', 'Tour de France Femmes', 'women', '2.WWT', 'FRA', '2027-07-30', '2027-08-07'),
  ('uci-road-world-championships/2027/w', 'UCI Road World Championships', 'women', 'CM', 'FRA', '2027-08-24', '2027-09-05'),
  ('la-vuelta-femenina/2027/w', 'La Vuelta Femenina', 'women', '2.WWT', 'ESP', '2027-10-03', '2027-10-10')
) as v(slug, name, gender, cls, country, s, e)
where not exists (select 1 from races r where r.gender = v.gender and r.dataride_id is not null
                    and r.uci_class = v.cls and abs(r.start_date - v.s::date) <= 3)
on conflict (pcs_slug) do nothing;
-- Ländercodes einheitlich wie bei der UCI (IOC): frühere ISO-Codes der vorläufigen Einträge korrigieren
update races set country = case country when 'DEU' then 'GER' when 'NLD' then 'NED' when 'CHE' then 'SUI'
                                        when 'DNK' then 'DEN' when 'ARE' then 'UAE' end
 where country in ('DEU', 'NLD', 'CHE', 'DNK', 'ARE');

-- Einmalig: künftige Spieltage mit dem alten Standard-Stichtag (Start 00:00) auf den neuen (Vortag 20:00) umstellen
update matchdays set deadline = ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin'
 where status = 'planned' and not waivers_done
   and deadline = starts_on::timestamp at time zone 'Europe/Berlin'
   and ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin' > now();

-- Platz eines Fahrers in der Saisonwertung eines Jahres (Summe der UCI-Punkte aus den Rennergebnissen)
create index if not exists race_events_date on race_events (event_date);
-- Saisonwertung je Jahr fest gespeichert (Rang und Punkte je Fahrer), damit das Fahrerfenster sie sofort zeigt.
-- Wird nach jedem Ergebnisabruf für das laufende und das vorige Jahr neu berechnet.
create table if not exists rider_season_stats (
  rider_slug  text not null references riders (pcs_slug) on delete cascade,
  year        int  not null,
  season_rank int  not null,
  points      numeric not null,
  riders      int  not null,       -- Fahrer mit Punkten in dieser Wertung und Saison
  primary key (rider_slug, year)
);

create or replace function refresh_season_stats(p_year int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from rider_season_stats where year = p_year;
  insert into rider_season_stats (rider_slug, year, season_rank, points, riders)
  with s as (
    select er.rider_slug, x.gender, sum(er.uci_points) pts
      from event_results er
      join race_events e on e.id = er.event_id
      join riders x on x.pcs_slug = er.rider_slug
     where e.event_date >= make_date(p_year, 1, 1) and e.event_date <= make_date(p_year, 12, 31)
       and er.uci_points > 0
     group by 1, 2)
  select rider_slug, p_year, (rank() over (partition by gender order by pts desc))::int, pts,
         (count(*) over (partition by gender))::int
    from s;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function rider_season_rank(p_slug text, p_year int)
returns table (season_rank int, points numeric, riders int)
language sql stable security definer set search_path = public as $$
  select season_rank, points, riders from rider_season_stats where rider_slug = p_slug and year = p_year;
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
  if p_drop is null then
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen Fahrer zum Abgeben wählen.'; end if;
  elsif not exists (select 1 from roster_entries where manager_id = v_me and rider_slug = p_drop and released_on is null) then
    raise exception 'Der abzugebende Fahrer ist nicht in deinem Kader.';
  end if;
  if not _rider_free(p_league, p_add, 'infinity') then raise exception 'Dieser Fahrer ist nicht frei.'; end if;
  select budget_left into v_budget from managers where id = v_me;
  if l.waiver_mode = 'faab' and (p_bid < 0 or p_bid > v_budget) then
    raise exception 'Gebot muss zwischen 0 und deinem Restbudget (%) liegen.', v_budget;
  end if;

  if p_immediate then
    -- Ersatz außer der Reihe bei Karriereende/Sperre
    if p_drop is null or not (select inactive from riders where pcs_slug = p_drop) then
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
  if c.drop_rider is null then
    if _open_roster_slots(c.manager_id) <= 0 then return 'Kader ist voll'; end if;
  elsif not exists (select 1 from roster_entries where manager_id = c.manager_id and rider_slug = c.drop_rider and released_on is null) then
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
  -- steht der abgegebene Fahrer in einer Aufstellung ab diesem Spieltag, rückt der neue nach
  update lineups x set rider_slug = c.add_rider
    from matchdays m where m.id = x.matchday_id and m.league_id = l.id and m.starts_on >= md.starts_on
     and x.manager_id = c.manager_id and x.rider_slug = c.drop_rider;
  update waiver_claims set status = 'won', processed_at = now(), matchday_id = md.id where id = c.id;
  -- andere Anträge mit demselben abzugebenden Fahrer werden ungültig
  update waiver_claims set status = 'lost', note = 'Abzugebender Fahrer schon getauscht', processed_at = now(), matchday_id = md.id
   where manager_id = c.manager_id and status = 'pending' and c.drop_rider is not null and drop_rider = c.drop_rider;
end $$;

-- Phase für den nächsten Spieltag: 'waiver' (Anträge sammeln), 'free' (sofort tauschen), null (kein Spieltag)
create or replace function transfer_phase(p_league uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l leagues; md matchdays;
begin
  select * into l from leagues where id = p_league;
  select * into md from matchdays where league_id = p_league and deadline > now() order by deadline limit 1;
  if not found then return jsonb_build_object('phase', null); end if;
  return jsonb_build_object('matchday', md.id,
    'phase', case when l.transfer_mode = 'waiver_free' and md.waivers_done then 'free' else 'waiver' end,
    'waiver_deadline', coalesce(md.waiver_deadline, md.deadline), 'deadline', md.deadline);
end $$;

-- Freie Phase: freien Fahrer sofort holen und dafür einen abgeben – gilt ab dem nächsten Spieltag
create or replace function free_move(p_league uuid, p_add text, p_drop text) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues; md matchdays; v_me uuid; e roster_entries;
begin
  v_me := _require_member(p_league);
  perform process_due(p_league);
  select * into l from leagues where id = p_league;
  if l.transfer_mode <> 'waiver_free' or l.status <> 'active' then raise exception 'In dieser Liga gibt es keine freie Phase.'; end if;
  select * into md from matchdays where league_id = p_league and deadline > now() order by deadline limit 1;
  if not found or not md.waivers_done then raise exception 'Die freie Phase beginnt erst nach der Waiver-Runde.'; end if;
  if p_drop is null then
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen Fahrer zum Abgeben wählen.'; end if;
  else
    select * into e from roster_entries where manager_id = v_me and rider_slug = p_drop and released_on is null;
    if not found then raise exception 'Der abzugebende Fahrer ist nicht in deinem Kader.'; end if;
  end if;
  -- frei = in keinem Kader für den nächsten Spieltag (abgegebene Fahrer sind sofort wieder frei)
  if exists (select 1 from roster_entries where league_id = p_league and rider_slug = p_add and released_on is null) then
    raise exception 'Dieser Fahrer ist schon vergeben.';
  end if;
  if not exists (select 1 from riders r where r.pcs_slug = p_add and r.gender = l.gender and not r.inactive) then
    raise exception 'Fahrer nicht verfügbar.';
  end if;
  if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  -- abgeben: erst in dieser Phase geholt → Eintrag entfernen, sonst endet er mit dem Spieltagstart
  if e.id is null then null;
  elsif e.acquired_on >= md.starts_on then
    delete from roster_entries where id = e.id;
  else
    update roster_entries set released_on = md.starts_on, released_at = now() where id = e.id;
  end if;
  -- holen: eigenen, gerade abgegebenen Fahrer zurücknehmen oder neu eintragen
  update roster_entries set released_on = null, released_at = null
   where manager_id = v_me and rider_slug = p_add and released_on = md.starts_on
     and released_at >= coalesce(md.waiver_deadline, md.deadline);
  if not found then
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'free', md.starts_on);
  end if;
  update lineups set rider_slug = p_add
   where matchday_id = md.id and manager_id = v_me and rider_slug = p_drop;
  insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, status, note, processed_at, matchday_id)
  values (p_league, v_me, p_add, p_drop, 'won', 'Freie Phase', now(), md.id);
end $$;

-- Nach Wechsel des Transfermodus: Standard-Fristen künftiger Spieltage neu setzen
create or replace function _reset_default_deadlines(p_league uuid, p_old_mode text) returns void
language plpgsql security definer set search_path = public as $$
declare m matchdays;
begin
  for m in select * from matchdays where league_id = p_league and status = 'planned' and not waivers_done
             and coalesce(waiver_deadline, deadline) > now() order by starts_on loop
    -- nur Standardwerte ersetzen, eigene Fristen des Admins bleiben
    if m.deadline in (m.starts_on::timestamp at time zone 'Europe/Berlin',
                      (m.starts_on - 1 + time '20:00')::timestamp at time zone 'Europe/Berlin') then
      update matchdays set deadline = _default_deadline(p_league, m.starts_on) where id = m.id;
    end if;
    update matchdays set waiver_deadline = _default_waiver_deadline(p_league, m.starts_on, m.id) where id = m.id;
  end loop;
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
                where manager_id = v_mgr and status = 'pending' and created_at <= coalesce(md.waiver_deadline, md.deadline)
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

-- Freie Kaderplätze eines Managers
create or replace function _open_roster_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries re where re.manager_id = m.id and re.released_on is null)::int
    from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Prüft Fahrer, die ein Manager im Tausch zusätzlich entlässt: im Kader, nicht Teil des Tauschs,
-- nicht schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen
create or replace function _check_trade_drops(p_manager uuid, p_drop text[], p_trade_riders text[], p_needed int) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(array_length(p_drop, 1), 0) <> p_needed then
    raise exception 'Bitte genau % Fahrer zum Entlassen auswählen, damit der Kader nicht zu groß wird.', p_needed;
  end if;
  if p_needed = 0 then return; end if;
  if (select count(distinct x) from unnest(p_drop) x) <> p_needed or p_drop && p_trade_riders then
    raise exception 'Zu entlassende Fahrer dürfen nicht Teil des Tauschs sein.';
  end if;
  if (select count(*) from roster_entries where manager_id = p_manager and released_on is null and rider_slug = any (p_drop)) <> p_needed then
    raise exception 'Zu entlassende Fahrer müssen im eigenen Kader stehen.';
  end if;
  if exists (select 1 from waiver_claims where manager_id = p_manager and status = 'pending' and drop_rider = any (p_drop)) then
    raise exception 'Ein Fahrer ist schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen.';
  end if;
end $$;

drop function if exists propose_trade(uuid, uuid, text[], text[]);
create or replace function propose_trade(p_league uuid, p_to uuid, p_give text[], p_take text[], p_drop text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_me uuid; v uuid; n_give int := coalesce(array_length(p_give, 1), 0); n_take int := coalesce(array_length(p_take, 1), 0);
begin
  v_me := _require_member(p_league);
  if (select status from leagues where id = p_league) <> 'active' then raise exception 'Tausch erst nach dem Draft.'; end if;
  if p_to = v_me or not exists (select 1 from managers where id = p_to and league_id = p_league) then
    raise exception 'Ungültiger Tauschpartner.';
  end if;
  if n_give = 0 or n_take = 0 then raise exception 'Beide Seiten müssen mindestens einen Fahrer abgeben.'; end if;
  if (select count(*) from roster_entries where manager_id = v_me and released_on is null and rider_slug = any (p_give)) <> n_give
     or (select count(*) from roster_entries where manager_id = p_to and released_on is null and rider_slug = any (p_take)) <> n_take then
    raise exception 'Die Fahrer müssen in den jeweiligen Kadern stehen.';
  end if;
  -- bekomme ich mehr Fahrer als ich abgebe, entlasse ich die Differenz
  perform _check_trade_drops(v_me, coalesce(p_drop, '{}'), p_give, greatest(n_take - n_give - _open_roster_slots(v_me), 0));
  insert into trades (league_id, from_manager, to_manager, give_riders, take_riders, from_drop)
  values (p_league, v_me, p_to, p_give, p_take, coalesce(p_drop, '{}')) returning id into v;
  perform _notify(p_to, '🔁 Neues Tauschangebot',
    (select team_name from managers where id = v_me) || ' bietet ' ||
    (select string_agg(_rname(x), ', ') from unnest(p_give) x) || ' für ' || (select string_agg(_rname(x), ', ') from unnest(p_take) x),
    '#/league/' || p_league || '/team');
  return v;
end $$;

drop function if exists respond_trade(uuid, boolean);
create or replace function respond_trade(p_trade uuid, p_accept boolean, p_drop text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if not found or t.status <> 'proposed' then raise exception 'Kein offenes Angebot.'; end if;
  if t.to_manager <> my_manager(t.league_id) then raise exception 'Dieses Angebot ist nicht an dich.'; end if;
  if p_accept then
    -- bekomme ich mehr Fahrer als ich abgebe, entlasse ich die Differenz
    perform _check_trade_drops(t.to_manager, coalesce(p_drop, '{}'), t.take_riders,
      greatest(array_length(t.give_riders, 1) - array_length(t.take_riders, 1) - _open_roster_slots(t.to_manager), 0));
  end if;
  update trades set status = case when p_accept then 'accepted' else 'declined' end,
                    accepted_at = case when p_accept then now() end,
                    to_drop = case when p_accept then coalesce(p_drop, '{}') else to_drop end
   where id = p_trade;
  perform _notify(t.from_manager, case when p_accept then '✅ Tausch angenommen' else '❌ Tausch abgelehnt' end,
    (select team_name from managers where id = t.to_manager) || case when p_accept
      then ' hat zugestimmt. Ausgeführt wird zum nächsten Stichtag.' else ' hat abgelehnt.' end,
    '#/league/' || t.league_id || '/team');
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
    if (select count(*) from roster_entries where manager_id = t.from_manager and released_on is null
          and rider_slug = any (t.give_riders || t.from_drop)) <> coalesce(array_length(t.give_riders || t.from_drop, 1), 0)
       or (select count(*) from roster_entries where manager_id = t.to_manager and released_on is null
          and rider_slug = any (t.take_riders || t.to_drop)) <> coalesce(array_length(t.take_riders || t.to_drop, 1), 0) then
      update trades set status = 'failed', note = 'Fahrer nicht mehr im Kader', done_at = now() where id = t.id;
      continue;
    end if;
    -- zusätzlich entlassene Fahrer werden frei
    foreach r in array t.from_drop loop perform _release(md.league_id, t.from_manager, r, md.starts_on); end loop;
    foreach r in array t.to_drop loop perform _release(md.league_id, t.to_manager, r, md.starts_on); end loop;
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
             where ((not m.waivers_done and coalesce(m.waiver_deadline, m.deadline) <= now())
                    or (not m.locked and m.deadline <= now()))
               and l.status = 'active' and (p_league is null or m.league_id = p_league)
             order by m.deadline
             for update of m skip locked loop
    -- Stichtag: Tausche ausführen, Wertungsmodus festhalten, Kader und Aufstellung sind ab jetzt fest
    if not md.locked and md.deadline <= now() then
      update matchdays m set scoring_mode = l.scoring_mode, lineup_size = l.lineup_size
        from leagues l where l.id = m.league_id and m.id = md.id;
      perform _process_trades(md.id);
    end if;
    -- Waiver-Runde (im zweiteiligen Modus vor dem Stichtag, danach beginnt die freie Phase)
    if not md.waivers_done and coalesce(md.waiver_deadline, md.deadline) <= now() then
      perform _process_waivers(md.id);
      perform _notify(w.manager_id, '📋 Waiver-Ergebnis',
          coalesce('Zuschlag: ' || string_agg(_rname(w.add_rider), ', ') filter (where w.status = 'won'), 'Kein Zuschlag')
          || coalesce(' · ohne Zuschlag: ' || string_agg(_rname(w.add_rider), ', ') filter (where w.status = 'lost'), ''),
          '#/league/' || md.league_id || '/waiver')
         from waiver_claims w where w.matchday_id = md.id and w.processed_at >= now() - interval '1 minute'
         group by w.manager_id;
      update matchdays set waivers_done = true where id = md.id;
      update leagues set last_waiver_run = now() where id = md.league_id;
    end if;
    if md.deadline <= now() then update matchdays set locked = true where id = md.id; end if;
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
  for md in update matchdays set status = 'closed', closed_at = now() where status = 'running' and ends_on < current_date
             returning * loop
    perform _notify(t.manager_id, '🏁 ' || md.name || ' abgeschlossen',
        coalesce((select round(sum(p.points))::text from _league_points(md.league_id) p
                   where p.matchday_id = md.id and p.manager_id = t.manager_id), '0')
        || ' Punkte · Gesamt Platz ' || t."position", '#/league/' || md.league_id || '/table')
       from _league_table(md.league_id) t;
  end loop;
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
-- Zeitplaner (pg_cron): startet die GitHub-Abläufe zu deutschen Uhrzeiten
-- Der GitHub-Schlüssel liegt verschlüsselt im Supabase Vault ("github_dispatch_token").
-- =====================================================================

do $$ begin
  create extension if not exists pg_net with schema extensions;
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_net/pg_cron nicht verfügbar: %', sqlerrm;   -- z. B. lokale Testdatenbank
end $$;

create or replace function dispatch_workflow(p_file text, p_inputs jsonb default '{}') returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text; v_id bigint;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_dispatch_token';
  if v_token is null then
    raise warning 'Kein github_dispatch_token im Vault – Ablauf % nicht gestartet', p_file;
    return null;
  end if;
  select net.http_post(
    url := 'https://api.github.com/repos/Schubidu93/UCI-Fantasy/actions/workflows/' || p_file || '/dispatches',
    body := jsonb_build_object('ref', 'main', 'inputs', coalesce(p_inputs, '{}'::jsonb)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'uci-fantasy-scheduler',
                                  'Content-Type', 'application/json')) into v_id;
  return v_id;
end $$;

-- läuft alle 15 Minuten
-- Wochen-Zusammenfassung (montags): Punkte der letzten 7 Tage, Tabellenplatz, bester Fahrer – je Manager mit Push
-- Draft-Report: bestmögliche Punkte jedes Kaders im Vorjahr – je Spieltag (Zeitraum ein Jahr früher) die besten
-- x der y gedrafteten Fahrer (x = wertende Fahrer laut Einstellung, y = Kadergröße). Ergebnis wird zwischengespeichert.
create table if not exists draft_projection (
  league_id  uuid not null references leagues (id) on delete cascade,
  manager_id uuid not null references managers (id) on delete cascade,
  points     numeric not null,
  per_md     jsonb not null default '{}',
  signature  text not null,          -- Spieltage + Wertungsmodus; ändert sich etwas, wird neu gerechnet
  computed_at timestamptz not null default now(),
  primary key (league_id, manager_id)
);
alter table draft_projection enable row level security;
drop policy if exists draft_projection_read on draft_projection;
create policy draft_projection_read on draft_projection for select using (is_member(league_id));

create or replace function draft_projection(p_league uuid)
returns table (manager_id uuid, points numeric, per_md jsonb)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare l leagues; v_x int; v_sig text;
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  select * into l from leagues where id = p_league;
  v_x := case when l.scoring_mode = 'lineup' then coalesce(l.lineup_size, l.roster_size) else l.roster_size end;
  v_sig := v_x || '|' || coalesce((select string_agg(starts_on || '-' || ends_on, ',' order by starts_on)
                                   from matchdays where league_id = p_league), 'jahr')
           || '|' || (select count(*) from draft_lots dl where dl.league_id = p_league and dl.manager_id is not null);
  if not exists (select 1 from draft_projection d where d.league_id = p_league and d.signature = v_sig) then
    delete from draft_projection d where d.league_id = p_league;
    insert into draft_projection (league_id, manager_id, points, per_md, signature)
    with team as (
      select distinct d.manager_id, d.rider_slug from draft_lots d where d.league_id = p_league and d.manager_id is not null),
    mds as (   -- Spieltage ein Jahr früher; ohne Spieltage: die ganze Vorsaison als ein Block
      select m.name, (m.starts_on - interval '1 year')::date s, (m.ends_on - interval '1 year')::date e
        from matchdays m where m.league_id = p_league
      union all
      select 'Vorjahr', make_date(extract(year from l.season_start)::int - 1, 1, 1), make_date(extract(year from l.season_start)::int - 1, 12, 31)
       where not exists (select 1 from matchdays where league_id = p_league)),
    rp as (
      select t.manager_id, md.name, t.rider_slug, sum(r.uci_points) p
        from team t cross join mds md
        join results r on r.rider_slug = t.rider_slug and r.result_date between md.s and md.e
       group by 1, 2, 3),
    best as (
      select rp.manager_id, rp.name, sum(rp.p) p from (
        select rp.*, row_number() over (partition by rp.manager_id, rp.name order by rp.p desc) rn from rp) rp
       where rn <= v_x group by 1, 2)
    select p_league, mg.id, coalesce(sum(b.p), 0), coalesce(jsonb_object_agg(b.name, round(b.p, 1)) filter (where b.name is not null), '{}'), v_sig
      from managers mg left join best b on b.manager_id = mg.id
     where mg.league_id = p_league group by mg.id;
  end if;
  return query select d.manager_id, d.points, d.per_md from draft_projection d where d.league_id = p_league;
end $$;

create or replace function weekly_summary() returns int
language plpgsql security definer set search_path = public as $$
declare lg leagues; n int := 0; k int;
begin
  for lg in select * from leagues where status = 'active' loop
    with week as (
      select s.manager_id, s.rider_slug, sum(s.points) pts
        from _score_rows(lg.id) s where s.result_date > current_date - 7 group by 1, 2),
    per_mgr as (
      select manager_id, sum(pts) total,
             (array_agg(rider_slug order by pts desc))[1] best_rider, max(pts) best_pts
        from week group by 1)
    insert into notifications (user_id, title, body, url)
    select m.user_id,
           '📊 Deine Woche: +' || round(coalesce(p.total, 0))::text || ' Punkte',
           lg.name || ': Platz ' || t."position" || ' von ' || (select count(*) from managers where league_id = lg.id)
             || coalesce(' · bester Fahrer ' || _rname(p.best_rider) || ' (+' || round(p.best_pts)::text || ')', ' · diese Woche keine Punkte'),
           '#/league/' || lg.id || '/home'
      from managers m
      join _league_table(lg.id) t on t.manager_id = m.id
      left join per_mgr p on p.manager_id = m.id
     where m.league_id = lg.id and m.user_id is not null
       and exists (select 1 from push_subscriptions x where x.user_id = m.user_id)
       -- nur während der Saison mit laufendem oder gerade beendetem Spieltag
       and exists (select 1 from matchdays md where md.league_id = lg.id
                     and md.starts_on <= current_date and md.ends_on >= current_date - 7);
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  return n;
end $$;

create or replace function scheduler_tick() returns void
language plpgsql security definer set search_path = public as $$
declare t timestamp := now() at time zone 'Europe/Berlin';
        h int := extract(hour from t); m int := extract(minute from t);
begin
  begin
    perform process_due(null);                     -- Stichtage (Waiver, Tausch) pünktlich abarbeiten
  exception when others then raise warning 'process_due: %', sqlerrm;
  end;
  if m < 15 then
    if h = 6 then perform dispatch_workflow('import-riders.yml'); end if;    -- Fahrer: Rang, Team, Geburtsdatum
    if h = 20 then perform dispatch_workflow('race-results.yml'); end if;    -- Rennergebnisse, Kalender, Punkte
    if h = 9 and extract(isodow from t) = 1 then perform weekly_summary(); end if;   -- Wochen-Zusammenfassung (Mo)
  end if;
  if exists (select 1 from notifications where sent_at is null) then
    perform dispatch_workflow('push.yml');
  end if;
end $$;

do $$ begin
  perform cron.schedule('uci-fantasy-tick', '*/15 * * * *', 'select public.scheduler_tick()');
exception when others then raise notice 'Zeitplan nicht angelegt: %', sqlerrm;
end $$;

-- =====================================================================
-- Rechte
-- =====================================================================

alter table riders          enable row level security;
alter table races           enable row level security;
alter table rider_season_stats enable row level security;
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
alter table keepers         enable row level security;
alter table app_config      enable row level security;   -- keine Policies: nur Service-Key
alter table push_subscriptions enable row level security;
alter table notifications   enable row level security;

do $$
declare t text;
begin
  -- öffentliche Stammdaten: lesbar für angemeldete Nutzer
  foreach t in array array['riders', 'races', 'results', 'sync_status', 'race_events', 'event_results', 'rider_season_stats'] loop
    execute format('drop policy if exists read_all on %I', t);
    execute format('create policy read_all on %I for select to authenticated using (true)', t);
  end loop;
  -- Ligadaten: nur für Mitglieder
  foreach t in array array['managers', 'draft_state', 'draft_lots', 'draft_bids', 'roster_entries',
                           'matchdays', 'trades', 'point_overrides', 'score_snapshot', 'admin_log', 'keepers'] loop
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

drop policy if exists own_read on push_subscriptions;
create policy own_read on push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists own_read on notifications;
create policy own_read on notifications for select to authenticated using (user_id = auth.uid());

-- interne Funktionen nicht direkt aufrufbar
do $$
declare f text;
begin
  foreach f in array array[
    '_require_member(uuid)', '_require_admin(uuid)', '_log(uuid,text,jsonb)', '_open_slots(uuid)',
    '_max_bid(uuid)', '_team_limit_ok(uuid,text,text)', '_rider_free(uuid,text,timestamptz)',
    '_release(uuid,uuid,text,date)', '_draft_next(uuid)', '_start_draft(uuid)', 'relink_event_riders()',
    'dispatch_workflow(text,jsonb)', 'results_from_events()', 'refresh_season_stats(int)', 'weekly_summary()', 'scheduler_tick()', '_notify(uuid,text,text,text)', '_notify_turn(uuid,uuid,uuid,text,timestamptz)', '_check_trade_drops(uuid,text[],text[],int)', '_open_roster_slots(uuid)', '_reset_default_deadlines(uuid,text)', '_snake_pick(uuid,text)', '_score_rows(uuid)',
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

-- Einmalig: künftige Spieltage in Ligen mit zweiteiligen Transfers ohne Waiver-Frist bekommen die Standardfristen
do $$ declare lg uuid; begin
  for lg in select distinct m.league_id from matchdays m join leagues l on l.id = m.league_id
             where l.transfer_mode = 'waiver_free' and m.status = 'planned'
               and (m.waiver_deadline is null
                    or (m.waiver_deadline at time zone 'Europe/Berlin')::time = time '20:00'
                    or m.deadline = ((m.starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin')
               and not m.waivers_done and m.deadline > now() loop
    perform _reset_default_deadlines(lg, 'waiver');
  end loop;
end $$;

-- Einmalig/bei jedem Einspielen: fehlende Punkte nachtragen
select results_from_events();

-- Ergebnisse vor 2025 werden nicht gespeichert (auch keine Rennen der Saison 2025, die schon im Herbst 2024 lagen)
delete from results where result_date < date '2025-01-01';
delete from races where coalesce(end_date, start_date) < date '2025-01-01';

-- Saisonwertungen beim Einspielen aufbauen (bzw. aktualisieren)
select refresh_season_stats(y) from generate_series(2025, extract(year from current_date)::int) y;
