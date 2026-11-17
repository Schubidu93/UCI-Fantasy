begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Tausch: ungleiche Tausche mit Entlassung, Zurückziehen, Veto, geplatzter Tausch, Push
insert into push_subscriptions (endpoint, user_id, p256dh, auth) values ('e1', user_id(1), 'k', 'a'), ('e2', user_id(2), 'k', 'a');
insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
select league(), manager(1), rider(n), 0, 'admin', current_date - 30 from unnest(array[5, 6, 7]) n;   -- Manager A: voller Kader (5)
select login(1);
select throws_ok($$select propose_trade(league(), manager(2), array[rider(1)], array[rider(3), rider(4)])$$, 'P0001',
  'Bitte genau 1 Fahrer zum Entlassen auswählen, damit der Kader nicht zu groß wird.', 'Ungleicher Tausch bei vollem Kader verlangt eine Entlassung');
select throws_ok($$select propose_trade(league(), manager(2), array[rider(1)], array[rider(3), rider(4)], array[rider(1)])$$, 'P0001',
  'Zu entlassende Fahrer dürfen nicht Teil des Tauschs sein.', 'Entlassener Fahrer darf nicht Teil des Tauschs sein');
create temp table tr (n int, id uuid);
insert into tr select 1, propose_trade(league(), manager(2), array[rider(1)], array[rider(3), rider(4)], array[rider(5)]);
select ok((select from_drop = array[rider(5)] from trades where id = (select id from tr where n = 1)), 'Entlassung wird mit dem Angebot gespeichert');
select login(2);
select throws_ok($$select cancel_trade((select id from tr where n = 1))$$, 'P0001', 'Nicht dein Angebot.', 'Empfänger kann das Angebot nicht zurückziehen');
select lives_ok($$select respond_trade((select id from tr where n = 1), true)$$, 'Empfänger nimmt an');
-- Veto des Admins innerhalb von 24 Stunden
select login(1);
select lives_ok($$select veto_trade((select id from tr where n = 1))$$, 'Admin legt Veto ein');
select is((select status from trades where id = (select id from tr where n = 1)), 'vetoed', 'Tausch ist gestoppt');
select is((select count(*)::int from notifications where title = '🚫 Tausch gestoppt'), 2, 'Beide Seiten bekommen Push „Tausch gestoppt“');
-- Veto nach 24 Stunden nicht mehr möglich
insert into tr select 2, propose_trade(league(), manager(2), array[rider(2)], array[rider(3)]);
update trades set status = 'accepted', accepted_at = now() - interval '25 hours' where id = (select id from tr where n = 2);
select throws_ok($$select veto_trade((select id from tr where n = 2))$$, 'P0001', 'Veto nur innerhalb von 24 Stunden nach Zustimmung.', 'Veto nach 24 Stunden ist nicht mehr möglich');
-- geplatzter Tausch: Fahrer vor dem Stichtag nicht mehr im Kader
select _release(league(), manager(2), rider(3), current_date);
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline) values (matchday(), league(), 'T', current_date + 3, current_date + 9, now() + interval '2 days');
select _process_trades(matchday());
select is((select status from trades where id = (select id from tr where n = 2)), 'failed', 'Tausch platzt, wenn ein Fahrer fehlt');
select is((select count(*)::int from notifications where title = '⚠️ Tausch geplatzt'), 2, 'Beide Seiten bekommen Push „Tausch geplatzt“');
-- Zurückziehen durch den Anbieter
insert into tr select 3, propose_trade(league(), manager(2), array[rider(2)], array[rider(4)]);
select lives_ok($$select cancel_trade((select id from tr where n = 3))$$, 'Anbieter zieht das Angebot zurück');
select is((select status from trades where id = (select id from tr where n = 3)), 'cancelled', 'Angebot ist zurückgezogen');
select ok(exists (select 1 from notifications where user_id = user_id(2) and title = '↩️ Tauschangebot zurückgezogen'), 'Empfänger bekommt Push „zurückgezogen“');
select * from finish();
rollback;
