-- Einmalig: künftige Spieltage in Ligen mit zweiteiligen Transfers ohne Waiver-Frist bekommen die Standardfristen
do $$ declare lg uuid; begin
  for lg in select distinct m.league_id from matchdays m join leagues l on l.id = m.league_id
             where l.transfer_mode = 'waiver_free' and m.status = 'planned'
               and (m.waiver_deadline is null
                    or (m.waiver_deadline at time zone 'Europe/Berlin')::time = time '20:00'
                    or m.deadline = ((m.starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin')
               and not m.waivers_done and m.deadline > now() loop
    perform _reset_default_deadlines(lg, 'waiver');
  end loop;
end $$;

