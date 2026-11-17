begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(13);

insert into waiver_claims (league_id,manager_id,add_rider,status)
values (league(),manager(1),rider(5),'pending'), (league(),manager(2),rider(6),'pending'),
       (league(),manager(2),rider(7),'lost');
insert into notifications (user_id,title) values (user_id(1),'Eigene Nachricht'),(user_id(2),'Fremde Nachricht');
insert into app_config values ('test-secret','nicht sichtbar');

-- Session-Identität ebenfalls wechseln: session_user=postgres wäre in _is_service() privilegiert.
set local session authorization authenticated;
select login(1);
select is((select count(*)::int from leagues), 1, 'Mitglied sieht genau seine Liga');
select is((select count(*)::int from managers), 2, 'Manager anderer Ligen sind verborgen');
select is((select count(*)::int from waiver_claims), 2, 'Eigener offener Antrag und abgeschlossene fremde Anträge sind sichtbar');
select is((select count(*)::int from waiver_claims where manager_id = manager(2) and status = 'pending'), 0,
  'Offener Antrag eines Mitspielers ist verborgen');
select is((select count(*)::int from notifications), 1, 'Nur eigene Benachrichtigungen sind sichtbar');
select is((select count(*)::int from app_config), 0, 'Interne Einstellungen bleiben verborgen');
select throws_ok($$insert into roster_entries (league_id,manager_id,rider_slug,source,acquired_on)
  values (league(),manager(1),rider(8),'admin',current_date)$$,
  '42501', null, 'Direkter Kader-Schreibzugriff scheitert an RLS');
select ok(not has_function_privilege(current_user,'public._process_waivers(uuid)','execute'), 'Interne Waiver-Verarbeitung kann nicht direkt aufgerufen werden');
select login(2);
select throws_ok($$select update_league_settings(league(),'{"name":"Unberechtigt"}')$$, 'P0001',
  'Nur der Liga-Admin darf das.', 'Normales Mitglied kann keine Liga-Einstellungen ändern');
select login(3);
select is((select count(*)::int from roster_entries where league_id = league(1)), 0, 'Mitglied einer anderen Liga sieht keinen fremden Kader');
select throws_ok($$select league_points(league(1))$$, 'P0001', 'Keine Berechtigung.', 'Fremde Liga-Punkte sind auch über RPC gesperrt');
select is((select count(*)::int from riders), 12, 'Angemeldete Nutzer können globale Stammdaten lesen');
reset session authorization;
set local session authorization anon;
select is((select count(*)::int from riders), 0, 'Anonyme Nutzer erhalten keine Stammdaten');
reset session authorization;

select * from finish();
rollback;
