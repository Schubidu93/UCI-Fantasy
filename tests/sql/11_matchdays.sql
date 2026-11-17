begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Spieltage anlegen, prüfen, löschen; Start und Abschluss mit Push
select login(2);
select throws_ok($$select upsert_matchday(league(), null, 'X', current_date + 5, current_date + 10)$$, 'P0001', 'Nur der Liga-Admin darf das.', 'Nur der Admin legt Spieltage an');
select login(1);
select throws_ok($$select upsert_matchday(league(), null, 'X', current_date + 10, current_date + 5)$$, 'P0001', 'Das Enddatum liegt vor dem Startdatum.', 'Ende vor Start wird abgelehnt');
create temp table md as select upsert_matchday(league(), null, 'Spieltag A', current_date + 15, current_date + 20) id;
select is((select status from matchdays where id = (select id from md)), 'planned', 'Neuer Spieltag ist geplant');
select ok((select waiver_deadline < deadline from matchdays where id = (select id from md)), 'Waiver-Auswertung liegt vor dem Stichtag (Waiver + freie Phase)');
select ok((select deadline from matchdays where id = (select id from md)) <= ((current_date + 15)::timestamp at time zone 'Europe/Berlin'), 'Stichtag liegt spätestens am Spieltagstart');
select lives_ok($$select upsert_matchday(league(), (select id from md), 'Spieltag A2', current_date + 16, current_date + 21)$$, 'Geplanter Spieltag ist änderbar');
select is((select name || ' ' || (starts_on - current_date) from matchdays where id = (select id from md)), 'Spieltag A2 16', 'Änderung ist gespeichert');
select lives_ok($$select delete_matchday((select id from md))$$, 'Geplanter Spieltag ist löschbar');
select is((select count(*)::int from matchdays where league_id = league()), 0, 'Spieltag ist gelöscht');
-- Start und Abschluss
insert into push_subscriptions (endpoint, user_id, p256dh, auth) values ('e1', user_id(1), 'k', 'a');
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline, waivers_done, locked)
values (matchday(), league(), 'Vergangen', current_date - 3, current_date - 1, now() - interval '4 days', true, true),
       (matchday(2), league(), 'Läuft', current_date, current_date + 3, now() - interval '1 hour', true, true);
select process_due(league());
select is((select status from matchdays where id = matchday(2)), 'running', 'Begonnener Spieltag läuft');
select run_maintenance();
select is((select status from matchdays where id = matchday()), 'closed', 'Beendeter Spieltag wird abgeschlossen');
select ok((select closed_at from matchdays where id = matchday()) is not null, 'Abschlusszeit ist gesetzt');
select ok(exists (select 1 from notifications where user_id = user_id(1) and title like '🏁 Vergangen abgeschlossen'), 'Push „Spieltag abgeschlossen“ an Manager mit Benachrichtigungen');
select ok(not exists (select 1 from notifications where user_id = user_id(2)), 'Ohne Benachrichtigungen keine Nachricht');
select is((select status from matchdays where id = matchday(2)), 'running', 'Laufender Spieltag bleibt offen');
select throws_ok($$select delete_matchday(matchday(2))$$, 'P0001', 'Laufende und abgeschlossene Spieltage sind gesperrt.', 'Laufender Spieltag ist nicht löschbar');
select * from finish();
rollback;
