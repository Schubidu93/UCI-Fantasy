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
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen Fahrer zum Abgeben wählen.'; end if;
  else
    select * into e from roster_entries where manager_id = v_me and rider_slug = p_drop and released_on is null;
    if not found then raise exception 'Der abzugebende Fahrer ist nicht in deinem Kader.'; end if;
  end if;
  -- frei = in keinem Kader für den nächsten Spieltag (abgegebene Fahrer sind sofort wieder frei)
  if exists (select 1 from roster_entries where league_id = p_league and rider_slug = p_add and released_on is null) then
    raise exception 'Dieser Fahrer ist schon vergeben.';
  end if;
  if not exists (select 1 from riders r where r.pcs_slug = p_add and r.gender = l.gender and not r.inactive) then
    raise exception 'Fahrer nicht verfügbar.';
  end if;
  if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
  -- abgeben: erst in dieser Phase geholt → Eintrag entfernen, sonst endet er mit dem Spieltagstart
  if e.id is null then null;
  elsif e.acquired_on >= md.starts_on then
    delete from roster_entries where id = e.id;
  else
    update roster_entries set released_on = md.starts_on, released_at = now() where id = e.id;
  end if;
  -- holen: eigenen, gerade abgegebenen Fahrer zurücknehmen oder neu eintragen
  update roster_entries set released_on = null, released_at = null
   where manager_id = v_me and rider_slug = p_add and released_on = md.starts_on
     and released_at >= coalesce(md.waiver_deadline, md.deadline);
  if not found then
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'free', md.starts_on);
  end if;
  update lineups set rider_slug = p_add
   where matchday_id = md.id and manager_id = v_me and rider_slug = p_drop;
  insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, status, note, processed_at, matchday_id)
  values (p_league, v_me, p_add, p_drop, 'won', 'Freie Phase', now(), md.id);
end $$;

