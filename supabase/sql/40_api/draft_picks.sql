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
  if l.draft_mode = 'blind' then
    update draft_state set lot_no = lot_no + 1, current_rider = p_rider, current_bid = 0, current_bidder = null,
           deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
     where league_id = p_league;
    return;
  end if;
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

