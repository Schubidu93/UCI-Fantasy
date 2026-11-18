begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Push: Anmeldung des Geräts, „Neue Punkte“, Wochen-Zusammenfassung
select login(1);
select lives_ok($$select save_push_subscription('geraet-1', 'k', 'a')$$, 'Gerät für Push anmelden');
select is((select user_id from push_subscriptions where endpoint = 'geraet-1'), user_id(1), 'Gerät gehört dem angemeldeten Nutzer');
select login(2);
select save_push_subscription('geraet-1', 'k2', 'a2');
select is((select user_id from push_subscriptions where endpoint = 'geraet-1'), user_id(2), 'Gleiches Gerät mit neuem Konto wechselt den Besitzer');
select delete_push_subscription('geraet-1');
select is((select count(*)::int from push_subscriptions), 0, 'Gerät abmelden');
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select save_push_subscription('x', 'k', 'a')$$, 'P0001', 'Bitte zuerst anmelden.', 'Ohne Anmeldung keine Push-Anmeldung');
-- Neue Punkte: laufender Spieltag, Sportler 1 (Manager A) punktet
insert into push_subscriptions (endpoint, user_id, p256dh, auth) values ('e1', user_id(1), 'k', 'a'), ('e2', user_id(2), 'k', 'a');
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline, status, waivers_done, locked)
values (matchday(), league(), 'Läuft', current_date - 2, current_date + 5, now() - interval '3 days', 'running', true, true);
insert into results (athlete_id, competition_id, label, result_date, points) values (rider(1), 'r', 'Etappe 1', current_date - 1, 25);
select is(notify_new_points(), 1, 'Eine Nachricht für den Manager mit neuen Punkten');
select ok(exists (select 1 from notifications where user_id = user_id(1) and title = '📈 Neue Punkte' and body like '%+25%'), 'Nachricht nennt die Punkte');
select is(notify_new_points(), 0, 'Dieselben Punkte werden nicht erneut gemeldet');
insert into results (athlete_id, competition_id, label, result_date, points) values (rider(1), 'r', 'Etappe 2', current_date, 5), (rider(3), 'r', 'Etappe 2', current_date, 7);
select is(notify_new_points(), 2, 'Neue Ergebnisse: je Manager eine Nachricht');
insert into results (athlete_id, competition_id, label, result_date, points) values (rider(2), 'alt', 'x', current_date - 30, 50);
select is(notify_new_points(), 0, 'Alte Ergebnisse (außerhalb des Spieltags) lösen nichts aus');
-- Wochen-Zusammenfassung
delete from notifications;
select is(weekly_summary(), 2, 'Wochen-Zusammenfassung an beide Manager');
select ok(exists (select 1 from notifications where user_id = user_id(1) and title = '📊 Deine Woche: +' || _fmt_pts(30) || ' Punkte'), 'Wochenpunkte stimmen (25 + 5)');
select ok(exists (select 1 from notifications where user_id = user_id(2) and body like '%Platz 2 von 2%'), 'Tabellenplatz steht in der Nachricht');
select * from finish();
rollback;
