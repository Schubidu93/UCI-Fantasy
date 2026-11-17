-- =====================================================================
-- Live-Auktions-Draft
-- =====================================================================

create or replace function _draft_next(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues; d draft_state; v_rider text; v_cur_pos int; v_next uuid;
        v_n int; v_pick int; v_round int; v_idx int; v_pos int;
begin
  select * into l from leagues where id = p_league;
  delete from draft_sealed where league_id = p_league;
  update draft_state set sealed_done = '{}', tie_bidders = null where league_id = p_league;
  select * into d from draft_state where league_id = p_league;

  if not exists (select 1 from managers m where m.league_id = p_league and _open_slots(m.id) > 0) then
    update draft_state set status = 'done', current_athlete = null, current_bid = 0, current_bidder = null,
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
    update draft_state set phase = 'snake', lot_no = v_pick, current_athlete = null, current_bid = 0, current_bidder = null,
                           nominator = v_next, deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
     where league_id = p_league;
    perform _notify_turn(p_league, v_next, d.nominator, 'Dein Pick (Nr. ' || v_pick || ') – du hast ' || l.bid_seconds || ' Sekunden.',
                         now() + make_interval(secs => l.bid_seconds));
    return;
  end if;

  if d.phase = 'auction' and l.draft_order = 'ranking' then
    select r.id into v_rider from athletes r
     where r.gender = l.gender and r.pool_rank is not null and not r.inactive
       and not exists (select 1 from draft_lots x where x.league_id = p_league and x.athlete_id = r.id)
     order by r.pool_rank, r.id limit 1;
    if v_rider is not null then
      update draft_state set lot_no = lot_no + 1, current_athlete = v_rider, current_bid = 0, current_bidder = null,
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
  update draft_state set current_athlete = null, current_bid = 0, current_bidder = null, deadline = null,
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
  if not exists (select 1 from athletes where gender = l.gender and pool_rank is not null) then
    raise exception 'Noch keine Fahrer importiert (Workflow "Fahrerliste importieren").';
  end if;

  update managers m set draft_position = s.rn, budget_left = l.budget
    from (select id, row_number() over (order by random()) rn from managers where league_id = p_league) s
   where m.id = s.id;
  -- Keeper vorab in die Kader (zählen wie gekauft; die Auktion überspringt sie)
  insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
    select p_league, k.manager_id, k.athlete_id, k.price, 'draft', l.season_start from keepers k where k.league_id = p_league;
  update managers m set budget_left = budget_left - coalesce((select sum(price) from keepers k where k.manager_id = m.id), 0)
   where m.league_id = p_league;
  insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
    select p_league, 0, k.athlete_id, k.manager_id, k.price from keepers k where k.league_id = p_league
  on conflict (league_id, athlete_id) do nothing;
  insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
  update draft_state set status = 'running', phase = 'auction', lot_no = 0, current_athlete = null, current_bid = 0,
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
  if d.current_athlete is null or d.deadline is null or now() >= d.deadline then raise exception 'Gerade wird kein Fahrer versteigert.'; end if;
  if l.draft_mode = 'blind' then
    if d.phase <> 'tiebreak' then raise exception 'In der Blind-Auktion wird verdeckt geboten.'; end if;
    if not (v_me = any (d.tie_bidders)) then raise exception 'Nur die Manager mit Gleichstand bieten im Stechen.'; end if;
    if p_amount <> d.current_bid + 1 then raise exception 'Im Stechen wird genau um 1 erhöht (auf %).', d.current_bid + 1; end if;
  end if;
  if d.current_bidder = v_me then raise exception 'Du bist schon Höchstbietender.'; end if;
  if _open_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll.'; end if;
  if p_amount < greatest(l.min_bid, d.current_bid + 1) then
    raise exception 'Gebot muss mindestens % sein.', greatest(l.min_bid, d.current_bid + 1);
  end if;
  v_max := _max_bid(v_me);
  if p_amount > v_max then raise exception 'Dein Höchstgebot ist %.', v_max; end if;
  if not _team_limit_ok(v_me, d.current_athlete) then raise exception 'Du hast schon die Höchstzahl an Fahrern dieses Profiteams.'; end if;

  update draft_state set current_bid = p_amount, current_bidder = v_me,
         deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
   where league_id = p_league;
  insert into draft_bids (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no, v_me, p_amount);
  -- Stechen: kann kein anderer mehr erhöhen, sofort Zuschlag
  if l.draft_mode = 'blind' and not exists (select 1 from unnest(d.tie_bidders) t
       where t <> v_me and _max_bid(t) >= p_amount + 1 and _team_limit_ok(t, d.current_athlete)) then
    perform _draft_award(p_league, v_me, p_amount);
  end if;
end $$;

-- Zuschlag für den aktuellen Fahrer (Blind-Auktion) und weiter zum nächsten
create or replace function _draft_award(p_league uuid, p_manager uuid, p_price int) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;
  if p_manager is not null then
    insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
    values (p_league, p_manager, d.current_athlete, p_price, 'draft', l.season_start);
    update managers set budget_left = budget_left - p_price where id = p_manager;
  end if;
  insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
  values (p_league, d.lot_no, d.current_athlete, p_manager, case when p_manager is null then 0 else p_price end);
  update draft_state set phase = case when phase = 'tiebreak' then 'auction' else phase end where league_id = p_league;
  perform _draft_next(p_league);
end $$;

-- Blind-Auktion: verdeckte Gebote auswerten. Höchstgebot gewinnt; bei Gleichstand Stechen um +1,
-- den Vorrang (wer ohne Erhöhung gewinnt) bekommen die Gleichauf-Bieter reihum.
create or replace function _blind_resolve(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_max int; v_tied uuid[]; v_lead uuid; v_pos int;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;
  -- Gebote offenlegen
  insert into draft_bids (league_id, lot_no, manager_id, amount)
    select league_id, d.lot_no, manager_id, amount from draft_sealed where league_id = p_league order by amount desc;
  select max(amount) into v_max from draft_sealed where league_id = p_league;
  if v_max is null then
    perform _draft_award(p_league, null, 0);            -- niemand hat geboten: übersprungen
    return;
  end if;
  select array_agg(s.manager_id order by m.draft_position) into v_tied
    from draft_sealed s join managers m on m.id = s.manager_id
   where s.league_id = p_league and s.amount = v_max;
  if array_length(v_tied, 1) = 1 then
    perform _draft_award(p_league, v_tied[1], v_max);
    return;
  end if;
  -- reihum: erster Gleichauf-Bieter nach dem letzten Vorrang
  select m.id, m.draft_position into v_lead, v_pos from managers m where m.id = any (v_tied)
   order by case when m.draft_position > d.tie_ptr then 0 else 1 end, m.draft_position limit 1;
  update draft_state set tie_ptr = v_pos where league_id = p_league;
  delete from draft_sealed where league_id = p_league;
  if not exists (select 1 from unnest(v_tied) t where t <> v_lead and _max_bid(t) >= v_max + 1) then
    perform _draft_award(p_league, v_lead, v_max);      -- niemand kann erhöhen
    return;
  end if;
  update draft_state set phase = 'tiebreak', tie_bidders = v_tied, sealed_done = '{}',
         current_bid = v_max, current_bidder = v_lead,
         deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
   where league_id = p_league;
end $$;

-- Blind-Auktion: verdecktes Gebot abgeben, ändern oder zurückziehen (0)
create or replace function draft_blind_bid(p_league uuid, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_me uuid; v_max int;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league for update;
  if l.draft_mode <> 'blind' then raise exception 'Diese Liga nutzt keine Blind-Auktion.'; end if;
  if d.status <> 'running' or d.phase <> 'auction' or d.current_athlete is null or d.deadline is null or now() >= d.deadline then
    raise exception 'Gerade wird kein Fahrer versteigert.';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    delete from draft_sealed where league_id = p_league and manager_id = v_me;
    update draft_state set sealed_done = array_remove(sealed_done, v_me), updated_at = now() where league_id = p_league;
    return;
  end if;
  if _open_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll.'; end if;
  v_max := _max_bid(v_me);
  if p_amount > v_max then raise exception 'Dein Höchstgebot ist %.', v_max; end if;
  if not _team_limit_ok(v_me, d.current_athlete) then raise exception 'Du hast schon die Höchstzahl an Fahrern dieses Profiteams.'; end if;
  insert into draft_sealed (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no, v_me, p_amount)
  on conflict (league_id, manager_id) do update set amount = excluded.amount, lot_no = excluded.lot_no, created_at = now();
  update draft_state set sealed_done = array_append(array_remove(sealed_done, v_me), v_me), updated_at = now()
   where league_id = p_league;
  -- Haben alle geboten, die noch bieten können? Dann sofort auswerten.
  if not exists (select 1 from managers m where m.league_id = p_league and _max_bid(m.id) >= 1
                    and _team_limit_ok(m.id, d.current_athlete)
                    and not exists (select 1 from draft_sealed s where s.league_id = p_league and s.manager_id = m.id)) then
    perform _blind_resolve(p_league);
  end if;
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
  if l.draft_mode = 'blind' and d.current_athlete is not null then
    if d.phase = 'tiebreak' then perform _draft_award(p_league, d.current_bidder, d.current_bid);
    else perform _blind_resolve(p_league); end if;
    return;
  end if;

  if d.current_athlete is not null then
    if d.current_bid > 0 and d.current_bidder is not null then
      insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
      values (p_league, d.current_bidder, d.current_athlete, d.current_bid, 'draft', l.season_start);
      update managers set budget_left = budget_left - d.current_bid where id = d.current_bidder;
      insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
      values (p_league, d.lot_no, d.current_athlete, d.current_bidder, d.current_bid);
    else
      insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
      values (p_league, d.lot_no, d.current_athlete, null, 0);
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
    select r.id into v_rider from athletes r
     where r.gender = l.gender and r.pool_rank is not null and not r.inactive
       and _athlete_free(p_league, r.id, 'infinity') and _team_limit_ok(d.nominator, r.id)
     order by r.pool_rank, r.id limit 1;
    if v_rider is null then raise exception 'Kein freier Fahrer mehr verfügbar.'; end if;
  end if;
  insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
  values (p_league, d.nominator, v_rider, 0, 'draft', l.season_start);
  insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
  values (p_league, d.lot_no, v_rider, d.nominator, 0)
  on conflict (league_id, athlete_id) do update set manager_id = excluded.manager_id, price = 0, lot_no = excluded.lot_no;
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
  if not _athlete_free(p_league, p_rider, 'infinity') then raise exception 'Dieser Fahrer ist nicht verfügbar.'; end if;
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
  if d.status <> 'running' or d.phase <> 'auction' or d.current_athlete is not null then
    raise exception 'Gerade kann niemand nominieren.';
  end if;
  if d.nominator is distinct from v_me and not is_admin(p_league) then raise exception 'Du bist nicht an der Reihe.'; end if;
  if exists (select 1 from draft_lots where league_id = p_league and athlete_id = p_rider)
     or not _athlete_free(p_league, p_rider, 'infinity') then
    raise exception 'Dieser Fahrer ist nicht verfügbar.';
  end if;
  if not _team_limit_ok(d.nominator, p_rider) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  if l.draft_mode = 'blind' then
    update draft_state set lot_no = lot_no + 1, current_athlete = p_rider, current_bid = 0, current_bidder = null,
           deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
     where league_id = p_league;
    return;
  end if;
  update draft_state set lot_no = lot_no + 1, current_athlete = p_rider, current_bid = 1, current_bidder = d.nominator,
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
  if not _athlete_free(p_league, p_rider, 'infinity') then raise exception 'Dieser Fahrer ist nicht verfügbar.'; end if;
  if not _team_limit_ok(d.nominator, p_rider) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
  values (p_league, d.nominator, p_rider, 1, 'draft', l.season_start);
  update managers set budget_left = budget_left - 1 where id = d.nominator;
  insert into draft_lots (league_id, lot_no, athlete_id, manager_id, price)
  values (p_league, d.lot_no + 1, p_rider, d.nominator, 1)
  on conflict (league_id, athlete_id) do update set manager_id = excluded.manager_id, price = 1;
  update draft_state set lot_no = lot_no + 1 where league_id = p_league;
  perform _draft_next(p_league);
end $$;
