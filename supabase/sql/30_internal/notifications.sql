-- Benachrichtigung an den Nutzer hinter einem Manager (Platzhalter ohne Konto werden übersprungen)
create or replace function _notify(p_manager uuid, p_title text, p_body text, p_url text) returns void
language sql security definer set search_path = public as $$
  insert into notifications (user_id, title, body, url)
  select user_id, p_title, p_body, p_url from managers where id = p_manager and user_id is not null
    and exists (select 1 from push_subscriptions s where s.user_id = managers.user_id);
$$;

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

