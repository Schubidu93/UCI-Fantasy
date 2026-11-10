create or replace function start_draft(p_league uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  perform _start_draft(p_league);
  perform _log(p_league, 'start_draft', null);
end $$;

-- Geplanten Draft starten, sobald die Zeit erreicht ist (darf jedes Mitglied auslösen)
create or replace function start_scheduled_draft(p_league uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare l leagues;
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' or l.draft_mode = 'offline' or l.draft_at is null or l.draft_at > now() then
    return false;
  end if;
  perform _start_draft(p_league);
  insert into admin_log (league_id, user_id, action, details) values (p_league, null, 'start_draft', '{"geplant": true}');
  return true;
end $$;

create or replace function schedule_draft(p_league uuid, p_at timestamptz) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin(p_league);
  if (select status from leagues where id = p_league) <> 'setup' then raise exception 'Der Draft wurde schon gestartet.'; end if;
  if p_at is not null and p_at < now() - interval '1 minute' then raise exception 'Der Zeitpunkt liegt in der Vergangenheit.'; end if;
  update leagues set draft_at = p_at where id = p_league;
  perform _log(p_league, 'schedule_draft', jsonb_build_object('at', p_at));
end $$;

