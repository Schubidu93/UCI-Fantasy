-- =====================================================================
-- Neue Saison: Liga kopieren und Keeper
-- =====================================================================

create or replace function copy_league(p_league uuid, p_name text, p_season_start date, p_season_end date,
                                       p_keeper_count int default 0, p_keeper_surcharge int default 5)
returns uuid language plpgsql security definer set search_path = public as $$
declare l leagues; v uuid;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league;
  -- alle Einstellungen der Vorsaison übernehmen (auch später hinzugekommene); Schlüssel, Zustand und Saison neu
  insert into leagues
  select (jsonb_populate_record(l, jsonb_build_object(
            'id', gen_random_uuid(), 'invite_code', substr(md5(gen_random_uuid()::text), 1, 10), 'created_at', now(),
            'status', 'setup', 'last_waiver_run', null, 'draft_at', null,
            'name', coalesce(nullif(trim(p_name), ''), l.name), 'season_start', p_season_start, 'season_end', p_season_end,
            'prev_league', p_league, 'keeper_count', coalesce(p_keeper_count, 0),
            'keeper_surcharge', coalesce(p_keeper_surcharge, 5)))).*
  returning id into v;
  insert into managers (league_id, user_id, team_name, prev_manager)
    select v, user_id, team_name, id from managers where league_id = p_league order by draft_position nulls last, joined_at;
  insert into draft_state (league_id) values (v);
  perform _log(p_league, 'copy_league', jsonb_build_object('new_league', v));
  return v;
end $$;

-- Mögliche Keeper des aufrufenden Managers: sein Kader am Ende der Vorsaison
create or replace function keeper_options(p_league uuid)
returns table (athlete_id text, prev_price int, price int, chosen boolean)
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid; l leagues;
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  return query
  select re.athlete_id, re.price, greatest(1, re.price + l.keeper_surcharge),
         exists (select 1 from keepers k where k.manager_id = v_me and k.athlete_id = re.athlete_id)
    from managers m join roster_entries re on re.manager_id = m.prev_manager and re.released_on is null
   where m.id = v_me
   order by re.price desc;
end $$;

create or replace function set_keepers(p_league uuid, p_riders text[]) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid; l leagues; v_sum int; v_n int := coalesce(array_length(p_riders, 1), 0);
begin
  v_me := _require_member(p_league);
  select * into l from leagues where id = p_league;
  if l.status <> 'setup' then raise exception 'Keeper können nur vor dem Draft gewählt werden.'; end if;
  if v_n > l.keeper_count then raise exception 'Du darfst höchstens % Keeper wählen.', l.keeper_count; end if;
  if exists (select 1 from unnest(p_riders) r where r not in (select o.athlete_id from keeper_options(p_league) o)) then
    raise exception 'Nur % aus deinem Vorjahreskader.', _word('many');
  end if;
  select coalesce(sum(o.price), 0) into v_sum from keeper_options(p_league) o where o.athlete_id = any (p_riders);
  if l.draft_mode in ('live', 'blind') and v_sum > l.budget - (l.roster_size - v_n) then
    raise exception 'Zu teuer: Keeper kosten %, es muss Budget für die restlichen Plätze bleiben.', v_sum;
  end if;
  delete from keepers where manager_id = v_me;
  insert into keepers (league_id, manager_id, athlete_id, price)
    select p_league, v_me, o.athlete_id, o.price from keeper_options(p_league) o where o.athlete_id = any (p_riders);
exception when unique_violation then
  raise exception 'Dieser % ist schon Keeper eines anderen Managers.', _word('one');
end $$;
