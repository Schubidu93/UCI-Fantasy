-- =====================================================================
-- Hilfsfunktionen
-- =====================================================================

-- Passt das Geschlecht des Sportlers zur Wertung der Liga (men, women, mixed)?
create or replace function _gender_ok(p_league_gender text, p_rider_gender text) returns boolean
language sql immutable as $$
  select p_league_gender = 'mixed' or p_league_gender = p_rider_gender;
$$;

create or replace function is_member(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from managers where league_id = p_league and user_id = auth.uid());
$$;

create or replace function is_admin(p_league uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from leagues where id = p_league and admin_user = auth.uid());
$$;

create or replace function my_manager(p_league uuid) returns uuid
language sql stable security definer set search_path = public as $$
  select id from managers where league_id = p_league and user_id = auth.uid();
$$;

create or replace function server_now() returns timestamptz
language sql stable as $$ select now(); $$;

create or replace function _is_service() returns boolean
language sql stable as $$
  select coalesce(auth.role(), '') = 'service_role' or session_user in ('postgres', 'supabase_admin');
$$;

create or replace function _require_member(p_league uuid) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  v := my_manager(p_league);
  if v is null then raise exception 'Du bist kein Mitglied dieser Liga.'; end if;
  return v;
end $$;

create or replace function _require_admin(p_league uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(p_league) then raise exception 'Nur der Liga-Admin darf das.'; end if;
end $$;

-- Benachrichtigung an den Nutzer hinter einem Manager (Platzhalter ohne Konto werden übersprungen)
create or replace function _notify(p_manager uuid, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, title, body, url)
  select user_id, p_title, p_body, p_url from managers where id = p_manager and user_id is not null
    and exists (select 1 from push_subscriptions s where s.user_id = managers.user_id);
$$;

-- Nachrichten sofort verschicken (statt beim nächsten Zeitplaner-Lauf in bis zu 15 Minuten)
create or replace function _push_soon() returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from notifications where sent_at is null) then
    begin
      perform dispatch_workflow('push.yml');
    exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
    end;
  end if;
end $$;

-- „Du bist dran“ im Draft: sofort senden (Ablauf direkt anstoßen), verfällt mit der Pick-Uhr
create or replace function _notify_turn(p_league uuid, p_manager uuid, p_prev uuid, p_text text, p_expires timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_manager is null or p_manager is not distinct from p_prev then return; end if;   -- gleicher Manager wie eben
  insert into notifications (user_id, title, body, url, expires_at)
  select m.user_id, '⏰ Du bist dran!', l.name || ': ' || p_text, '#/league/' || p_league || '/draft', p_expires
    from managers m join leagues l on l.id = m.league_id
   where m.id = p_manager and m.user_id is not null
     and exists (select 1 from push_subscriptions s where s.user_id = m.user_id);
  if found then
    begin
      perform dispatch_workflow('push.yml');
    exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
    end;
  end if;
end $$;

create or replace function _rname(p_slug text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select name from athletes where id = p_slug), p_slug);
$$;

create or replace function vapid_public_key() returns text
language sql stable security definer set search_path = public as $$
  select value from app_config where key = 'vapid_public';
$$;

create or replace function save_push_subscription(p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  insert into push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

create or replace function delete_push_subscription(p_endpoint text) returns void
language sql security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

create or replace function _log(p_league uuid, p_action text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_log (league_id, user_id, action, details) values (p_league, auth.uid(), p_action, p_details);
$$;

-- Freie Kaderplätze eines Managers
create or replace function _open_slots(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select l.roster_size - (select count(*) from roster_entries r where r.manager_id = m.id and r.released_on is null)::int
  from managers m join leagues l on l.id = m.league_id where m.id = p_manager;
$$;

-- Höchstgebot im Draft: Restbudget minus (offene Plätze − 1) × Mindestgebot
create or replace function _max_bid(p_manager uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when _open_slots(m.id) <= 0 then 0 else m.budget_left - (_open_slots(m.id) - 1) end
  from managers m where m.id = p_manager;
$$;

-- Würde der Manager mit diesem Fahrer die Grenze pro Profiteam überschreiten?
create or replace function _team_limit_ok(p_manager uuid, p_rider text, p_without text default null) returns boolean
language sql stable security definer set search_path = public as $$
  select l.max_per_team is null
      or rd.team is null
      or (select count(*) from roster_entries re join athletes x on x.id = re.athlete_id
          where re.manager_id = m.id and re.released_on is null and x.team = rd.team
            and re.athlete_id is distinct from p_without) < l.max_per_team
  from managers m join leagues l on l.id = m.league_id, athletes rd
  where m.id = p_manager and rd.id = p_rider;
$$;

-- Ist ein Fahrer in der Liga frei? Abgegebene Fahrer sind gesperrt, wenn sie
-- seit p_locked_since abgegeben wurden (= bis zum nächsten Stichtag).
create or replace function _athlete_free(p_league uuid, p_rider text, p_locked_since timestamptz) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from athletes r join leagues l on l.id = p_league
                 where r.id = p_rider and _gender_ok(l.gender, r.gender) and _selectable(r.pool_rank))
     and not exists (select 1 from roster_entries
                     where league_id = p_league and athlete_id = p_rider
                       and (released_on is null or released_at >= p_locked_since));
$$;

create or replace function _release(p_league uuid, p_manager uuid, p_rider text, p_on date) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  update roster_entries set released_on = p_on, released_at = now()
   where league_id = p_league and manager_id = p_manager and athlete_id = p_rider and released_on is null;
  return found;
end $$;
