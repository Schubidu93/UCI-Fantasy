begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(12);

update leagues set transfer_mode = 'waiver' where id = league();
select is(_default_deadline(league(),date '2028-01-15'), timestamptz '2028-01-14 19:00:00+00', 'Winter-Stichtag entspricht 20 Uhr Berlin');
select is(_default_deadline(league(),date '2028-07-15'), timestamptz '2028-07-14 18:00:00+00', 'Sommer-Stichtag berücksichtigt Sommerzeit');
update leagues set transfer_mode = 'waiver_free', scoring_mode = 'lineup', lineup_size = 1 where id = league();
select is(_default_deadline(league(),date '2028-01-15'), timestamptz '2028-01-14 23:00:00+00', 'Zweiteiliger Modus sperrt zum Spieltagstart um Mitternacht Berlin');
select login(1);
insert into matchdays (id,league_id,name,starts_on,ends_on,deadline,waiver_deadline)
values (matchday(),league(),'Fristen-Test',current_date + 10,current_date + 20,
        now() + interval '1 hour',now() + interval '30 minutes');
select lives_ok($$select set_lineup(matchday(),array[rider(1)])$$, 'Eigene Aufstellung kann vor dem Stichtag gesetzt werden');
select throws_ok($$select set_lineup(matchday(),array[rider(3)])$$, 'P0001',
  'Du kannst nur Fahrer aus deinem Kader aufstellen.', 'Fremder Fahrer ist in der Aufstellung nicht erlaubt');
select throws_ok($$select upsert_matchday(league(),null,'Überlappung',current_date + 20,current_date + 25)$$,
  'P0001', 'Spieltage dürfen sich nicht überlappen.', 'Auch gemeinsamer Randtag gilt als Überschneidung');
update matchdays set waiver_deadline = now() where id = matchday();
select throws_ok($$select delete_matchday(matchday())$$, 'P0001',
  'Laufende und abgeschlossene Spieltage sind gesperrt.', 'Spieltag wird bereits an der Waiver-Frist gegen Löschen gesperrt');
update matchdays set deadline = now() where id = matchday();
select throws_ok($$select set_lineup(matchday(),array[rider(2)])$$, 'P0001',
  'Der Stichtag für diesen Spieltag ist vorbei.', 'Genau am Stichtag ist die Aufstellung gesperrt');
select is(process_due(league()), 1, 'Fällige Waiver-Frist und Stichtag werden abgearbeitet');
select ok((select locked and waivers_done from matchdays where id = matchday()), 'Kader ist gesperrt und Waiver-Runde abgeschlossen');
select is((select scoring_mode from matchdays where id = matchday()), 'lineup', 'Wertungsmodus wird am Stichtag festgehalten');
select is(process_due(league()), 0, 'Erneute Fristverarbeitung bleibt folgenlos');

select * from finish();
rollback;
