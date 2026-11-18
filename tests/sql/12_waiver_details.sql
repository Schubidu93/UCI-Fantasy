begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Waiver-Anträge: Prüfungen, Reihenfolge, Zurückziehen, Sofort-Ersatz, voller Kader
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline)
values (matchday(), league(), 'Nächster', current_date + 10, current_date + 20, now() + interval '5 days');
select login(1);
select throws_ok($$select submit_waiver(league(), rider(5), rider(3))$$, 'P0001', 'Der abzugebende ' || _word('one') || ' ist nicht in deinem Kader.', 'Abgabe muss aus dem eigenen Kader sein');
select throws_ok($$select submit_waiver(league(), rider(3), null)$$, 'P0001', 'Dieser ' || _word('one') || ' ist nicht frei.', 'Vergebener Sportler kann nicht beantragt werden');
create temp table c (n int, id uuid);
insert into c select 1, submit_waiver(league(), rider(5), null);
insert into c select 2, submit_waiver(league(), rider(6), rider(1));
select is((select array_agg(priority order by n) from waiver_claims w join c on c.id = w.id), array[1, 2], 'Anträge sind in Reihenfolge des Eingangs');
select lives_ok($$select reorder_waivers(league(), array[(select id from c where n = 2), (select id from c where n = 1)])$$, 'Reihenfolge ist änderbar');
select is((select array_agg(priority order by n) from waiver_claims w join c on c.id = w.id), array[2, 1], 'Neue Reihenfolge ist gespeichert');
select login(2);
select cancel_waiver((select id from c where n = 1));
select is((select status from waiver_claims where id = (select id from c where n = 1)), 'pending', 'Fremder Antrag kann nicht zurückgezogen werden');
select login(1);
select cancel_waiver((select id from c where n = 1));
select is((select status from waiver_claims where id = (select id from c where n = 1)), 'cancelled', 'Eigener Antrag wird zurückgezogen');
-- Sofort-Ersatz nur bei Karriereende/Sperre
select throws_ok($$select submit_waiver(league(), rider(7), rider(2), 0, true)$$, 'P0001', 'Sofort-Ersatz nur für ' || _word('many') || ' mit Karriereende oder Sperre.', 'Sofort-Ersatz nur für inaktive Sportler');
select admin_mark_inactive(league(), rider(2), true);
select lives_ok($$select submit_waiver(league(), rider(7), rider(2), 0, true)$$, 'Inaktiver Sportler wird sofort ersetzt');
select ok(exists (select 1 from roster_entries where manager_id = manager(1) and athlete_id = rider(7) and released_on is null)
      and not exists (select 1 from roster_entries where manager_id = manager(1) and athlete_id = rider(2) and released_on is null), 'Ersatz ist im Kader, inaktiver Sportler nicht mehr');
-- voller Kader verlangt eine Abgabe
insert into roster_entries (league_id, manager_id, athlete_id, price, source, acquired_on)
select league(), manager(1), rider(n), 0, 'admin', current_date - 30 from unnest(array[8, 9, 10]) n;
select is(_open_roster_slots(manager(1)), 0, 'Kader ist voll');
select throws_ok($$select submit_waiver(league(), rider(11), null)$$, 'P0001', 'Dein Kader ist voll – bitte einen ' || _word('oneAcc') || ' zum Abgeben wählen.', 'Voller Kader braucht eine Abgabe');
select * from finish();
rollback;
