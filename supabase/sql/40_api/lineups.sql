create or replace function set_lineup(p_matchday uuid, p_riders text[]) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; l leagues; v_me uuid;
begin
  select * into md from matchdays where id = p_matchday;
  if not found then raise exception 'Spieltag nicht gefunden.'; end if;
  v_me := _require_member(md.league_id);
  select * into l from leagues where id = md.league_id;
  if now() >= md.deadline then raise exception 'Der Stichtag für diesen Spieltag ist vorbei.'; end if;
  if l.scoring_mode <> 'lineup' then raise exception 'Die Liga wertet den Gesamtkader.'; end if;
  if coalesce(array_length(p_riders, 1), 0) <> l.lineup_size then
    raise exception 'Bitte genau % Fahrer aufstellen.', l.lineup_size;
  end if;
  if exists (select 1 from unnest(p_riders) r where not exists (
      select 1 from roster_entries re where re.manager_id = v_me and re.rider_slug = r and re.released_on is null)) then
    raise exception 'Du kannst nur Fahrer aus deinem Kader aufstellen.';
  end if;
  delete from lineups where matchday_id = p_matchday and manager_id = v_me;
  insert into lineups (matchday_id, manager_id, rider_slug) select p_matchday, v_me, unnest(p_riders);
end $$;

