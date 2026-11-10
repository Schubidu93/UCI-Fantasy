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

