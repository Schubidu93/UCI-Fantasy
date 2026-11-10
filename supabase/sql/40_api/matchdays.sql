-- alte Signatur ohne Waiver-Frist entfernen (sonst ist der Aufruf mehrdeutig)
drop function if exists upsert_matchday(uuid, uuid, text, date, date, timestamptz);
create or replace function upsert_matchday(p_league uuid, p_id uuid, p_name text, p_start date, p_end date,
                                           p_deadline timestamptz default null, p_waiver_deadline timestamptz default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid; m matchdays; v_deadline timestamptz; v_wd timestamptz;
begin
  perform _require_admin(p_league);
  v_deadline := coalesce(p_deadline, _default_deadline(p_league, p_start));
  v_wd := coalesce(p_waiver_deadline, _default_waiver_deadline(p_league, p_start, p_id));
  if v_wd > v_deadline then raise exception 'Die Waiver-Auswertung muss vor dem Stichtag liegen.'; end if;
  if p_end < p_start then raise exception 'Das Enddatum liegt vor dem Startdatum.'; end if;
  if p_id is null then
    insert into matchdays (league_id, name, starts_on, ends_on, deadline, waiver_deadline)
    values (p_league, p_name, p_start, p_end, v_deadline, v_wd) returning id into v;
  else
    select * into m from matchdays where id = p_id and league_id = p_league;
    if not found then raise exception 'Spieltag nicht gefunden.'; end if;
    if m.waivers_done or coalesce(m.waiver_deadline, m.deadline) <= now() then
      raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.';
    end if;
    update matchdays set name = p_name, starts_on = p_start, ends_on = p_end, deadline = v_deadline, waiver_deadline = v_wd
     where id = p_id;
    v := p_id;
  end if;
  return v;
exception when exclusion_violation then
  raise exception 'Spieltage dürfen sich nicht überlappen.';
end $$;

create or replace function delete_matchday(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m matchdays;
begin
  select * into m from matchdays where id = p_id;
  if not found then raise exception 'Spieltag nicht gefunden.'; end if;
  perform _require_admin(m.league_id);
  if m.waivers_done or coalesce(m.waiver_deadline, m.deadline) <= now() then
    raise exception 'Laufende und abgeschlossene Spieltage sind gesperrt.';
  end if;
  delete from matchdays where id = p_id;
end $$;

