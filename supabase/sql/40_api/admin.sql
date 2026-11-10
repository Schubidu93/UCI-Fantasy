-- =====================================================================
-- Admin-Werkzeuge
-- =====================================================================

create or replace function admin_set_override(p_league uuid, p_matchday uuid, p_manager uuid, p_rider text,
                                              p_points numeric, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if coalesce(trim(p_reason), '') = '' then raise exception 'Bitte einen Grund angeben.'; end if;
  if p_points is null then
    delete from point_overrides where matchday_id = p_matchday and manager_id = p_manager and rider_slug = p_rider;
  else
    insert into point_overrides (league_id, matchday_id, manager_id, rider_slug, points, reason, created_by)
    values (p_league, p_matchday, p_manager, p_rider, p_points, p_reason, auth.uid())
    on conflict (matchday_id, manager_id, rider_slug)
    do update set points = excluded.points, reason = excluded.reason, created_by = excluded.created_by, created_at = now();
  end if;
  perform _log(p_league, 'override', jsonb_build_object('matchday', p_matchday, 'manager', p_manager,
               'rider', p_rider, 'points', p_points, 'reason', p_reason));
end $$;

-- Kader korrigieren (sofort wirksam, wird protokolliert)
create or replace function admin_roster_fix(p_league uuid, p_manager uuid, p_add text, p_drop text,
                                            p_price int default 0, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if p_drop is not null and not _release(p_league, p_manager, p_drop, current_date) then
    raise exception 'Fahrer % ist nicht im Kader.', p_drop;
  end if;
  if p_add is not null then
    if not _rider_free(p_league, p_add, 'infinity') then raise exception 'Fahrer % ist nicht frei.', p_add; end if;
    if _open_slots(p_manager) <= 0 then raise exception 'Der Kader ist voll.'; end if;
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, p_manager, p_add, coalesce(p_price, 0), 'admin', current_date);
  end if;
  perform _log(p_league, 'roster_fix', jsonb_build_object('manager', p_manager, 'add', p_add, 'drop', p_drop, 'reason', p_reason));
end $$;

create or replace function admin_mark_inactive(p_league uuid, p_rider text, p_inactive boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  update riders set inactive = p_inactive where pcs_slug = p_rider;
  perform _log(p_league, 'mark_inactive', jsonb_build_object('rider', p_rider, 'inactive', p_inactive));
end $$;

