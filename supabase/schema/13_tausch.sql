-- =====================================================================
-- Tausch zwischen Managern
-- =====================================================================

-- Freie Kaderplätze eines Managers
create or replace function _open_roster_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries re where re.manager_id = m.id and re.released_on is null)::int
    from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Prüft Fahrer, die ein Manager im Tausch zusätzlich entlässt: im Kader, nicht Teil des Tauschs,
-- nicht schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen
create or replace function _check_trade_drops(p_manager uuid, p_drop text[], p_trade_riders text[], p_needed int) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(array_length(p_drop, 1), 0) <> p_needed then
    raise exception 'Bitte genau % % zum Entlassen auswählen, damit der Kader nicht zu groß wird.', p_needed, _word('many');
  end if;
  if p_needed = 0 then return; end if;
  if (select count(distinct x) from unnest(p_drop) x) <> p_needed or p_drop && p_trade_riders then
    raise exception 'Zu entlassende % dürfen nicht Teil des Tauschs sein.', _word('many');
  end if;
  if (select count(*) from roster_entries where manager_id = p_manager and released_on is null and athlete_id = any (p_drop)) <> p_needed then
    raise exception 'Zu entlassende % müssen im eigenen Kader stehen.', _word('many');
  end if;
  if exists (select 1 from waiver_claims where manager_id = p_manager and status = 'pending' and drop_athlete = any (p_drop)) then
    raise exception 'Ein % ist schon in einem offenen Waiver-Antrag zur Abgabe vorgesehen.', _word('one');
  end if;
end $$;

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
  if n_give = 0 or n_take = 0 then raise exception 'Beide Seiten müssen mindestens einen % abgeben.', _word('oneAcc'); end if;
  if (select count(*) from roster_entries where manager_id = v_me and released_on is null and athlete_id = any (p_give)) <> n_give
     or (select count(*) from roster_entries where manager_id = p_to and released_on is null and athlete_id = any (p_take)) <> n_take then
    raise exception 'Die % müssen in den jeweiligen Kadern stehen.', _word('many');
  end if;
  -- bekomme ich mehr Fahrer als ich abgebe, entlasse ich die Differenz
  perform _check_trade_drops(v_me, coalesce(p_drop, '{}'), p_give, greatest(n_take - n_give - _open_roster_slots(v_me), 0));
  insert into trades (league_id, from_manager, to_manager, give_athletes, take_athletes, from_drop)
  values (p_league, v_me, p_to, p_give, p_take, coalesce(p_drop, '{}')) returning id into v;
  perform _notify(p_to, '🔁 Neues Tauschangebot',
    (select team_name from managers where id = v_me) || ' bietet ' ||
    (select string_agg(_rname(x), ', ') from unnest(p_give) x) || ' für ' || (select string_agg(_rname(x), ', ') from unnest(p_take) x),
    '#/league/' || p_league || '/team');
  perform _push_soon();
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
    perform _check_trade_drops(t.to_manager, coalesce(p_drop, '{}'), t.take_athletes,
      greatest(array_length(t.give_athletes, 1) - array_length(t.take_athletes, 1) - _open_roster_slots(t.to_manager), 0));
  end if;
  update trades set status = case when p_accept then 'accepted' else 'declined' end,
                    accepted_at = case when p_accept then now() end,
                    to_drop = case when p_accept then coalesce(p_drop, '{}') else to_drop end
   where id = p_trade;
  perform _notify(t.from_manager, case when p_accept then '✅ Tausch angenommen' else '❌ Tausch abgelehnt' end,
    (select team_name from managers where id = t.to_manager) || case when p_accept
      then ' hat zugestimmt. Ausgeführt wird zum nächsten Stichtag.' else ' hat abgelehnt.' end,
    '#/league/' || t.league_id || '/team');
  perform _push_soon();
end $$;

create or replace function cancel_trade(p_trade uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t trades;
begin
  select * into t from trades where id = p_trade for update;
  if t.from_manager <> my_manager(t.league_id) then raise exception 'Nicht dein Angebot.'; end if;
  update trades set status = 'cancelled' where id = p_trade and status in ('proposed', 'accepted');
  if found then
    perform _notify(t.to_manager, '↩️ Tauschangebot zurückgezogen',
      (select team_name from managers where id = t.from_manager) || ' hat das Angebot zurückgezogen.', '#/league/' || t.league_id || '/team');
    perform _push_soon();
  end if;
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
  perform _notify(m.id, '🚫 Tausch gestoppt', 'Der Liga-Admin hat den Tausch zwischen '
      || (select team_name from managers where id = t.from_manager) || ' und '
      || (select team_name from managers where id = t.to_manager) || ' per Veto gestoppt.', '#/league/' || t.league_id || '/team')
    from managers m where m.id in (t.from_manager, t.to_manager);
  perform _push_soon();
end $$;

-- Angenommene Tauschs werden zum nächsten Stichtag nach Ablauf der Vetofrist ausgeführt
create or replace function _process_trades(p_md uuid) returns void
language plpgsql security definer set search_path = public as $$
declare md matchdays; t trades; r text;
begin
  select * into md from matchdays where id = p_md;
  for t in select * from trades where league_id = md.league_id and status = 'accepted'
                                  and accepted_at + interval '24 hours' <= md.deadline order by accepted_at loop
    if (select count(*) from roster_entries where manager_id = t.from_manager and released_on is null
          and athlete_id = any (t.give_athletes || t.from_drop)) <> coalesce(array_length(t.give_athletes || t.from_drop, 1), 0)
       or (select count(*) from roster_entries where manager_id = t.to_manager and released_on is null
          and athlete_id = any (t.take_athletes || t.to_drop)) <> coalesce(array_length(t.take_athletes || t.to_drop, 1), 0) then
      update trades set status = 'failed', note = _word('one') || ' nicht mehr im Kader', done_at = now() where id = t.id;
      perform _notify(m.id, '⚠️ Tausch geplatzt', 'Der Tausch zwischen '
          || (select team_name from managers where id = t.from_manager) || ' und '
          || (select team_name from managers where id = t.to_manager) || ' wurde nicht ausgeführt: ' || _word('one') || ' nicht mehr im Kader.',
          '#/league/' || md.league_id || '/team')
        from managers m where m.id in (t.from_manager, t.to_manager);
      continue;
    end if;
    -- zusätzlich entlassene Fahrer werden frei
    foreach r in array t.from_drop loop perform _release(md.league_id, t.from_manager, r, md.starts_on); end loop;
    foreach r in array t.to_drop loop perform _release(md.league_id, t.to_manager, r, md.starts_on); end loop;
    foreach r in array t.give_athletes loop
      perform _release(md.league_id, t.from_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, athlete_id, source, acquired_on) values (md.league_id, t.to_manager, r, 'trade', md.starts_on);
    end loop;
    foreach r in array t.take_athletes loop
      perform _release(md.league_id, t.to_manager, r, md.starts_on);
      insert into roster_entries (league_id, manager_id, athlete_id, source, acquired_on) values (md.league_id, t.from_manager, r, 'trade', md.starts_on);
    end loop;
    update trades set status = 'done', done_at = now() where id = t.id;
    perform _notify(t.from_manager, '✅ Tausch ausgeführt', 'Neu im Kader: ' || (select string_agg(_rname(x), ', ') from unnest(t.take_athletes) x) || ' · abgegeben: ' || (select string_agg(_rname(x), ', ') from unnest(t.give_athletes) x),
      '#/league/' || md.league_id || '/team');
    perform _notify(t.to_manager, '✅ Tausch ausgeführt', 'Neu im Kader: ' || (select string_agg(_rname(x), ', ') from unnest(t.give_athletes) x) || ' · abgegeben: ' || (select string_agg(_rname(x), ', ') from unnest(t.take_athletes) x),
      '#/league/' || md.league_id || '/team');
  end loop;
end $$;
