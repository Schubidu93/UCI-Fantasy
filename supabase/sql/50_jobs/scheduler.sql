create or replace function scheduler_tick() returns void
language plpgsql security definer set search_path = public as $$
declare t timestamp := now() at time zone 'Europe/Berlin';
        h int := extract(hour from t); m int := extract(minute from t);
begin
  begin
    perform process_due(null);                     -- Stichtage (Waiver, Tausch) pünktlich abarbeiten
  exception when others then raise warning 'process_due: %', sqlerrm;
  end;
  if m < 15 then
    if h = 6 then perform dispatch_workflow('import-riders.yml'); end if;    -- Fahrer: Rang, Team, Geburtsdatum
    if h = 20 then perform dispatch_workflow('race-results.yml'); end if;    -- Rennergebnisse, Kalender, Punkte
    if h = 9 and extract(isodow from t) = 1 then perform weekly_summary(); end if;   -- Wochen-Zusammenfassung (Mo)
  end if;
  if exists (select 1 from notifications where sent_at is null) then
    perform dispatch_workflow('push.yml');
  end if;
  -- Feedback, das noch nicht verschickt ist (höchstens 3 Versuche, z. B. solange der Mailzugang fehlt)
  if exists (select 1 from feedback where sent_at is null and attempts < 3 and created_at < now() - interval '5 minutes') then
    perform dispatch_workflow('feedback.yml');
  end if;
end $$;

do $$ begin
  perform cron.schedule('uci-fantasy-tick', '*/15 * * * *', 'select public.scheduler_tick()');
exception when others then raise notice 'Zeitplan nicht angelegt: %', sqlerrm;
end $$;

