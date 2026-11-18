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
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen % zum Abgeben wählen.', _word('oneAcc'); end if;
  elsif not exists (select 1 from roster_entries where manager_id = v_me and athlete_id = p_drop and released_on is null) then
    raise exception 'Der abzugebende % ist nicht in deinem Kader.', _word('one');
  end if;
  if not _athlete_free(p_league, p_add, 'infinity') then raise exception 'Dieser % ist nicht frei.', _word('one'); end if;
  select budget_left into v_budget from managers where id = v_me;
  if l.waiver_mode = 'faab' and (p_bid < 0 or p_bid > v_budget) then
    raise exception 'Gebot muss zwischen 0 und deinem Restbudget (%) liegen.', v_budget;
  end if;

  if p_immediate then
    -- Ersatz außer der Reihe bei Karriereende/Sperre
    if p_drop is null or not (select inactive from athletes where id = p_drop) then
      raise exception 'Sofort-Ersatz nur für % mit Karriereende oder Sperre.', _word('many');
    end if;
    if not _athlete_free(p_league, p_add, coalesce(l.last_waiver_run, '-infinity')) then
      raise exception 'Dieser % ist bis zum nächsten Stichtag gesperrt.', _word('one');
    end if;
    if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro % erreicht.', _word('team'); end if;
    perform _release(p_league, v_me, p_drop, current_date);
    insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'waiver', current_date);
    insert into waiver_claims (league_id, manager_id, add_athlete, drop_athlete, status, note, processed_at)
    values (p_league, v_me, p_add, p_drop, 'won', 'Sofort-Ersatz', now()) returning id into v_id;
    return v_id;
  end if;

  insert into waiver_claims (league_id, manager_id, add_athlete, drop_athlete, bid, priority)
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
  if c.drop_athlete is null then
    if _open_roster_slots(c.manager_id) <= 0 then return 'Kader ist voll'; end if;
  elsif not exists (select 1 from roster_entries where manager_id = c.manager_id and athlete_id = c.drop_athlete and released_on is null) then
    return 'Abzugebender ' || _word('one') || ' nicht mehr im Kader';
  end if;
  if not _athlete_free(l.id, c.add_athlete, now()) then return _word('one') || ' schon vergeben'; end if;
  if not _team_limit_ok(c.manager_id, c.add_athlete, c.drop_athlete) then return 'Grenze pro ' || _word('team'); end if;
  if l.waiver_mode = 'faab' and c.bid > (select budget_left from managers where id = c.manager_id) then
    return 'Restbudget reicht nicht';
  end if;
  return null;
end $$;

create or replace function _execute_claim(c waiver_claims, l leagues, md matchdays) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _release(l.id, c.manager_id, c.drop_athlete, md.starts_on);
  insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
  values (l.id, c.manager_id, c.add_athlete, case when l.waiver_mode = 'faab' then c.bid else 0 end, 'waiver', md.starts_on);
  if l.waiver_mode = 'faab' then
    update managers set budget_left = budget_left - c.bid where id = c.manager_id;
  end if;
  -- steht der abgegebene Sportler in einer Aufstellung ab diesem Spieltag, rückt der neue nach (wenn er passt)
  perform _lineup_swap(l.id, c.manager_id, c.drop_athlete, c.add_athlete, md.starts_on);
  update waiver_claims set status = 'won', processed_at = now(), matchday_id = md.id where id = c.id;
  -- andere Anträge mit demselben abzugebenden Fahrer werden ungültig
  update waiver_claims set status = 'lost', note = 'Abzugebender ' || _word('one') || ' schon getauscht', processed_at = now(), matchday_id = md.id
   where manager_id = c.manager_id and status = 'pending' and c.drop_athlete is not null and drop_athlete = c.drop_athlete;
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
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen % zum Abgeben wählen.', _word('oneAcc'); end if;
  else
    select * into e from roster_entries where manager_id = v_me and athlete_id = p_drop and released_on is null;
    if not found then raise exception 'Der abzugebende % ist nicht in deinem Kader.', _word('one'); end if;
  end if;
  -- frei = in keinem Kader für den nächsten Spieltag (abgegebene Fahrer sind sofort wieder frei)
  if exists (select 1 from roster_entries where league_id = p_league and athlete_id = p_add and released_on is null) then
    raise exception 'Dieser % ist schon vergeben.', _word('one');
  end if;
  if not exists (select 1 from athletes r where r.id = p_add and _gender_ok(l.gender, r.gender) and not r.inactive and _eligible(l, r)) then
    raise exception '% nicht verfügbar.', _word('one');
  end if;
  if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro % erreicht.', _word('team'); end if;
  -- abgeben: erst in dieser Phase geholt → Eintrag entfernen, sonst endet er mit dem Spieltagstart
  if e.id is null then null;
  elsif e.acquired_on >= md.starts_on then
    delete from roster_entries where id = e.id;
  else
    update roster_entries set released_on = md.starts_on, released_at = now() where id = e.id;
  end if;
  -- holen: eigenen, gerade abgegebenen Fahrer zurücknehmen oder neu eintragen
  update roster_entries set released_on = null, released_at = null
   where manager_id = v_me and athlete_id = p_add and released_on = md.starts_on
     and released_at >= coalesce(md.waiver_deadline, md.deadline);
  if not found then
    insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'free', md.starts_on);
  end if;
  perform _lineup_swap(p_league, v_me, p_drop, p_add, md.starts_on);
  insert into waiver_claims (league_id, manager_id, add_athlete, drop_athlete, status, note, processed_at, matchday_id)
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
