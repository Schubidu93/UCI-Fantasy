-- Blind-Auktion: verdecktes Gebot abgeben, ändern oder zurückziehen (0)
create or replace function draft_blind_bid(p_league uuid, p_amount int) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_me uuid; v_max int;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league for update;
  if l.draft_mode <> 'blind' then raise exception 'Diese Liga nutzt keine Blind-Auktion.'; end if;
  if d.status <> 'running' or d.phase <> 'auction' or d.current_rider is null or d.deadline is null or now() >= d.deadline then
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
  if not _team_limit_ok(v_me, d.current_rider) then raise exception 'Du hast schon die Höchstzahl an Fahrern dieses Profiteams.'; end if;
  insert into draft_sealed (league_id, lot_no, manager_id, amount) values (p_league, d.lot_no, v_me, p_amount)
  on conflict (league_id, manager_id) do update set amount = excluded.amount, lot_no = excluded.lot_no, created_at = now();
  update draft_state set sealed_done = array_append(array_remove(sealed_done, v_me), v_me), updated_at = now()
   where league_id = p_league;
  -- Haben alle geboten, die noch bieten können? Dann sofort auswerten.
  if not exists (select 1 from managers m where m.league_id = p_league and _max_bid(m.id) >= 1
                    and _team_limit_ok(m.id, d.current_rider)
                    and not exists (select 1 from draft_sealed s where s.league_id = p_league and s.manager_id = m.id)) then
    perform _blind_resolve(p_league);
  end if;
end $$;

