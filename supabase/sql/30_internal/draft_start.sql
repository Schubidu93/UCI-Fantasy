create or replace function _start_draft(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
declare l leagues;
begin
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' then raise exception 'Der Draft wurde schon gestartet.'; end if;
  if l.draft_mode = 'offline' then raise exception 'Diese Liga nutzt den Offline-Import.'; end if;
  if (select count(*) from managers where league_id = p_league) < 2 then raise exception 'Mindestens 2 Manager nötig.'; end if;
  if not exists (select 1 from riders where gender = l.gender and uci_rank is not null) then
    raise exception 'Noch keine Fahrer importiert (Workflow "Fahrerliste importieren").';
  end if;

  update managers m set draft_position = s.rn, budget_left = l.budget
    from (select id, row_number() over (order by random()) rn from managers where league_id = p_league) s
   where m.id = s.id;
  -- Keeper vorab in die Kader (zählen wie gekauft; die Auktion überspringt sie)
  insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
    select p_league, k.manager_id, k.rider_slug, k.price, 'draft', l.season_start from keepers k where k.league_id = p_league;
  update managers m set budget_left = budget_left - coalesce((select sum(price) from keepers k where k.manager_id = m.id), 0)
   where m.league_id = p_league;
  insert into draft_lots (league_id, lot_no, rider_slug, manager_id, price)
    select p_league, 0, k.rider_slug, k.manager_id, k.price from keepers k where k.league_id = p_league
  on conflict (league_id, rider_slug) do nothing;
  insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
  update draft_state set status = 'running', phase = 'auction', lot_no = 0, current_rider = null, current_bid = 0,
                         current_bidder = null, deadline = null, nominator = null, updated_at = now()
   where league_id = p_league;
  update leagues set status = 'drafting' where id = p_league;
  perform _draft_next(p_league);
  perform _notify(m.id, '🚴 Der Draft startet jetzt!', l.name || ': Ab in den Draft-Raum.', '#/league/' || p_league || '/draft')
     from managers m where m.league_id = p_league;
end $$;

