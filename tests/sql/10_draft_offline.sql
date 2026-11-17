begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Offline-Draft eintragen: Prüfung ohne Speichern, Fehler bei falschen Kadern, Übernahme
delete from roster_entries where league_id = league();
update leagues set status = 'setup', roster_size = 5, budget = 100 where id = league();
select login(1);
create temp table rows_ok as select jsonb_agg(jsonb_build_object('manager_id', case when n <= 5 then manager(1) else manager(2) end, 'rider_slug', rider(n), 'price', 10)) j
  from generate_series(1, 10) n;
select is(array_length(import_offline_draft(league(), (select jsonb_agg(e) from jsonb_array_elements((select j from rows_ok)) e
  where e->>'rider_slug' <> rider(10)), false), 1) > 0, true, 'Zu kleiner Kader wird gemeldet');
select is(coalesce(array_length(import_offline_draft(league(), (select j from rows_ok), false), 1), 0), 0, 'Vollständige Kader sind ohne Fehler');
select is((select count(*)::int from roster_entries where league_id = league()), 0, 'Prüfung ohne Übernahme speichert nichts');
select is(coalesce(array_length(import_offline_draft(league(), (select j from rows_ok), true), 1), 0), 0, 'Übernahme läuft ohne Fehler');
select is((select count(*)::int from roster_entries where league_id = league() and source = 'offline'), 10, 'Alle Fahrer sind in den Kadern');
select is((select budget_left from managers where id = manager(1)), 50, 'Restbudget = Budget minus Kaufpreise');
select is((select status from leagues where id = league()), 'active', 'Liga ist danach aktiv');
select is(import_offline_draft(league(), (select j from rows_ok), true), array['Die Kader sind bereits fixiert.'], 'Zweite Übernahme wird abgelehnt');
select * from finish();
rollback;
