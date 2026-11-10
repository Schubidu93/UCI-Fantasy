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
  if not _team_limit_ok(v_me, d.current_rider) then raise exception 'Du hast schon die Höchstzahl an Fahrern dieses Profiteams.'; end if;

  update draft_state set current_bid = p_amount, current_bidder = v_me,
         deadline = now() + make_interval(secs => l.bid_seconds), updated_at = now()
   where league_id = p_league;
  insert into draft_bids (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no, v_me, p_amount);
  -- Stechen: kann kein anderer mehr erhöhen, sofort Zuschlag
  if l.draft_mode = 'blind' and not exists (select 1 from unnest(d.tie_bidders) t
       where t <> v_me and _max_bid(t) >= p_amount + 1 and _team_limit_ok(t, d.current_rider)) then
    perform _draft_award(p_league, v_me, p_amount);
  end if;
end $$;

