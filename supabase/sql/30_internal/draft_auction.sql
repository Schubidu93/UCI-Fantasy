-- Zuschlag für den aktuellen Fahrer (Blind-Auktion) und weiter zum nächsten
create or replace function _draft_award(p_league uuid, p_manager uuid, p_price int) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;
  if p_manager is not null then
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, p_manager, d.current_rider, p_price, 'draft', l.season_start);
    update managers set budget_left = budget_left - p_price where id = p_manager;
  end if;
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
  values (p_league, d.lot_no, d.current_rider, p_manager, case when p_manager is null then 0 else p_price end);
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

