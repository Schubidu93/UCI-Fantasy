-- Angenommene Tauschs werden zum nächsten Stichtag nach Ablauf der Vetofrist ausgeführt
create or replace function _process_trades(p_md uuid) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; t trades; r text;
begin
  select * into md from matchdays where id = p_md;
  for t in select * from trades where league_id = md.league_id and status = 'accepted'
                                  and accepted_at + interval '24 hours' <= md.deadline order by accepted_at loop
    if (select count(*) from roster_entries where manager_id = t.from_manager and released_on is null
          and rider_slug = any (t.give_riders || t.from_drop)) <> coalesce(array_length(t.give_riders || t.from_drop, 1), 0)
       or (select count(*) from roster_entries where manager_id = t.to_manager and released_on is null
          and rider_slug = any (t.take_riders || t.to_drop)) <> coalesce(array_length(t.take_riders || t.to_drop, 1), 0) then
      update trades set status = 'failed', note = 'Fahrer nicht mehr im Kader', done_at = now() where id = t.id;
      continue;
    end if;
    -- zusätzlich entlassene Fahrer werden frei
    foreach r in array t.from_drop loop perform _release(md.league_id, t.from_manager, r, md.starts_on); end loop;
    foreach r in array t.to_drop loop perform _release(md.league_id, t.to_manager, r, md.starts_on); end loop;
    foreach r in array t.give_riders loop
      perform _release(md.league_id, t.from_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, rider_slug, source, acquired_on) values (md.league_id, t.to_manager, r, 'trade', md.starts_on);
    end loop;
    foreach r in array t.take_riders loop
      perform _release(md.league_id, t.to_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, rider_slug, source, acquired_on) values (md.league_id, t.from_manager, r, 'trade', md.starts_on);
    end loop;
    update trades set status = 'done', done_at = now() where id = t.id;
  end loop;
end $$;

