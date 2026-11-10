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

