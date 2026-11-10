drop function if exists propose_trade(uuid, uuid, text[], text[]);
create or replace function propose_trade(p_league uuid, p_to uuid, p_give text[], p_take text[], p_drop text[] default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_me uuid; v uuid; n_give int := coalesce(array_length(p_give, 1), 0); n_take int := coalesce(array_length(p_take, 1), 0);
begin
  v_me := _require_member(p_league);
  if (select status from leagues where id = p_league) <> 'active' then raise exception 'Tausch erst nach dem Draft.'; end if;
  if p_to = v_me or not exists (select 1 from managers where id = p_to and league_id = p_league) then
    raise exception 'Ungültiger Tauschpartner.';
  end if;
  if n_give = 0 or n_take = 0 then raise exception 'Beide Seiten müssen mindestens einen Fahrer abgeben.'; end if;
  if (select count(*) from roster_entries where manager_id = v_me and released_on is null and rider_slug = any (p_give)) <> n_give
     or (select count(*) from roster_entries where manager_id = p_to and released_on is null and rider_slug = any (p_take)) <> n_take then
    raise exception 'Die Fahrer müssen in den jeweiligen Kadern stehen.';
  end if;
  -- bekomme ich mehr Fahrer als ich abgebe, entlasse ich die Differenz
  perform _check_trade_drops(v_me, coalesce(p_drop, '{}'), p_give, greatest(n_take - n_give - _open_roster_slots(v_me), 0));
  insert into trades (league_id, from_manager, to_manager, give_riders, take_riders, from_drop)
  values (p_league, v_me, p_to, p_give, p_take, coalesce(p_drop, '{}')) returning id into v;
  perform _notify(p_to, '🔁 Neues Tauschangebot',
    (select team_name from managers where id = v_me) || ' bietet ' ||
    (select string_agg(_rname(x), ', ') from unnest(p_give) x) || ' für ' || (select string_agg(_rname(x), ', ') from unnest(p_take) x),
    '#/league/' || p_league || '/team');
  return v;
end $$;

drop function if exists respond_trade(uuid, boolean);
create or replace function respond_trade(p_trade uuid, p_accept boolean, p_drop text[] default '{}') returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if not found or t.status <> 'proposed' then raise exception 'Kein offenes Angebot.'; end if;
  if t.to_manager <> my_manager(t.league_id) then raise exception 'Dieses Angebot ist nicht an dich.'; end if;
  if p_accept then
    -- bekomme ich mehr Fahrer als ich abgebe, entlasse ich die Differenz
    perform _check_trade_drops(t.to_manager, coalesce(p_drop, '{}'), t.take_riders,
      greatest(array_length(t.give_riders, 1) - array_length(t.take_riders, 1) - _open_roster_slots(t.to_manager), 0));
  end if;
  update trades set status = case when p_accept then 'accepted' else 'declined' end,
                    accepted_at = case when p_accept then now() end,
                    to_drop = case when p_accept then coalesce(p_drop, '{}') else to_drop end
   where id = p_trade;
  perform _notify(t.from_manager, case when p_accept then '✅ Tausch angenommen' else '❌ Tausch abgelehnt' end,
    (select team_name from managers where id = t.to_manager) || case when p_accept
      then ' hat zugestimmt. Ausgeführt wird zum nächsten Stichtag.' else ' hat abgelehnt.' end,
    '#/league/' || t.league_id || '/team');
end $$;

create or replace function cancel_trade(p_trade uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if t.from_manager <> my_manager(t.league_id) then raise exception 'Nicht dein Angebot.'; end if;
  update trades set status = 'cancelled' where id = p_trade and status in ('proposed', 'accepted');
end $$;

create or replace function veto_trade(p_trade uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  perform _require_admin(t.league_id);
  if t.status <> 'accepted' or now() > t.accepted_at + interval '24 hours' then
    raise exception 'Veto nur innerhalb von 24 Stunden nach Zustimmung.';
  end if;
  update trades set status = 'vetoed' where id = p_trade;
  perform _log(t.league_id, 'veto_trade', jsonb_build_object('trade', p_trade));
end $$;

