-- Snake-Draft: Pick ausführen (p_rider null = automatisch bester freier Fahrer nach UCI-Rang)
create or replace function _snake_pick(p_league uuid, p_rider text) returns void
language plpgsql security definer set search_path = public as $$
declare d draft_state; l leagues; v_rider text := p_rider;
begin
  select * into l from leagues where id = p_league;
  select * into d from draft_state where league_id = p_league;
  if v_rider is null then
    select r.pcs_slug into v_rider from riders r
     where r.gender = l.gender and r.uci_rank is not null and not r.inactive
       and _rider_free(p_league, r.pcs_slug, 'infinity') and _team_limit_ok(d.nominator, r.pcs_slug)
     order by r.uci_rank, r.pcs_slug limit 1;
    if v_rider is null then raise exception 'Kein freier Fahrer mehr verfügbar.'; end if;
  end if;
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
  values (p_league, d.nominator, v_rider, 0, 'draft', l.season_start);
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
  values (p_league, d.lot_no, v_rider, d.nominator, 0)
  on conflict (league_id, rider_slug) do update set manager_id = excluded.manager_id, price = 0, lot_no = excluded.lot_no;
  perform _draft_next(p_league);
end $$;

