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
  if l.draft_mode = 'blind' and d.current_rider is not null then
    if d.phase = 'tiebreak' then perform _draft_award(p_league, d.current_bidder, d.current_bid);
    else perform _blind_resolve(p_league); end if;
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

