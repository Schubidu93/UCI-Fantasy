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

