-- =====================================================================
-- Waiver
-- =====================================================================

create or replace function submit_waiver(p_league uuid, p_add text, p_drop text, p_bid int default 0,
                                         p_immediate boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leagues; v_me uuid; v_id uuid; v_budget int;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  if l.status <> 'active' then raise exception 'Waiver sind erst nach dem Draft möglich.'; end if;
  if p_drop is null then
    if _open_roster_slots(v_me) <= 0 then raise exception 'Dein Kader ist voll – bitte einen Fahrer zum Abgeben wählen.'; end if;
  elsif not exists (select 1 from roster_entries where manager_id = v_me and rider_slug = p_drop and released_on is null) then
    raise exception 'Der abzugebende Fahrer ist nicht in deinem Kader.';
  end if;
  if not _rider_free(p_league, p_add, 'infinity') then raise exception 'Dieser Fahrer ist nicht frei.'; end if;
  select budget_left into v_budget from managers where id = v_me;
  if l.waiver_mode = 'faab' and (p_bid < 0 or p_bid > v_budget) then
    raise exception 'Gebot muss zwischen 0 und deinem Restbudget (%) liegen.', v_budget;
  end if;

  if p_immediate then
    -- Ersatz außer der Reihe bei Karriereende/Sperre
    if p_drop is null or not (select inactive from riders where pcs_slug = p_drop) then
      raise exception 'Sofort-Ersatz nur für Fahrer mit Karriereende oder Sperre.';
    end if;
    if not _rider_free(p_league, p_add, coalesce(l.last_waiver_run, '-infinity')) then
      raise exception 'Dieser Fahrer ist bis zum nächsten Stichtag gesperrt.';
    end if;
    if not _team_limit_ok(v_me, p_add, p_drop) then raise exception 'Grenze pro Profiteam erreicht.'; end if;
    perform _release(p_league, v_me, p_drop, current_date);
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    values (p_league, v_me, p_add, 0, 'waiver', current_date);
    insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, status, note, processed_at)
    values (p_league, v_me, p_add, p_drop, 'won', 'Sofort-Ersatz', now()) returning id into v_id;
    return v_id;
  end if;

  insert into waiver_claims (league_id, manager_id, add_rider, drop_rider, bid, priority)
  values (p_league, v_me, p_add, p_drop, case when l.waiver_mode = 'faab' then p_bid else 0 end,
          coalesce((select max(priority) from waiver_claims where manager_id = v_me and status = 'pending'), 0) + 1)
  returning id into v_id;
  return v_id;
end $$;

create or replace function cancel_waiver(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update waiver_claims c set status = 'cancelled', processed_at = now()
   where c.id = p_id and c.status = 'pending'
     and c.manager_id in (select id from managers where user_id = auth.uid());
end $$;

create or replace function reorder_waivers(p_league uuid, p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid;
begin
  v_me := _require_member(p_league);
  update waiver_claims c set priority = x.ord
    from unnest(p_ids) with ordinality x(id, ord)
   where c.id = x.id and c.manager_id = v_me and c.status = 'pending';
end $$;

