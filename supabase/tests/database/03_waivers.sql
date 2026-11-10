begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(11);

update leagues set waiver_mode = 'faab' where id = league();
insert into matchdays (id,league_id,name,starts_on,ends_on,deadline)
values (matchday(),league(),'Waiver-Test',current_date + 10,current_date + 20,now() + interval '1 day');
insert into lineups (matchday_id,manager_id,rider_slug) values (matchday(),manager(2),rider(3));
insert into waiver_claims (league_id,manager_id,add_rider,drop_rider,bid)
values (league(),manager(1),rider(5),rider(1),10),
       (league(),manager(2),rider(5),rider(3),20),
       (league(),manager(2),rider(7),rider(3),1);
select lives_ok($$select _process_waivers(matchday())$$, 'FAAB-Runde wird ausgeführt');
select ok(exists (select 1 from roster_entries where manager_id = manager(2) and rider_slug = rider(5) and released_on is null), 'Höchstes Gebot erhält den Fahrer');
select is((select budget_left from managers where id = manager(2)), 60, 'FAAB-Gebot wird einmal vom Budget abgezogen');
select is((select released_on from roster_entries where manager_id = manager(2) and rider_slug = rider(3)), current_date + 10, 'Abgabe gilt ab dem nächsten Spieltag');
select is((select rider_slug from lineups where matchday_id = matchday() and manager_id = manager(2)), rider(5), 'Neuer Fahrer ersetzt die Abgabe in der Aufstellung');
select is((select status from waiver_claims where manager_id = manager(1) and add_rider = rider(5)), 'lost', 'Unterlegenes Gebot verliert');
select is((select status from waiver_claims where manager_id = manager(2) and add_rider = rider(7)), 'lost', 'Alternative mit derselben Abgabe wird ungültig');

insert into waiver_claims (league_id,manager_id,add_rider,drop_rider,bid)
values (league(),manager(1),rider(6),rider(2),10), (league(),manager(2),rider(6),rider(4),10);
select _process_waivers(matchday());
select ok(exists (select 1 from roster_entries where manager_id = manager(2) and rider_slug = rider(6) and released_on is null), 'Gleichstand bei null Punkten folgt der umgekehrten Draft-Reihenfolge');
select login(1);
select throws_ok($$select submit_waiver(league(),rider(8),rider(1),71)$$, 'P0001',
  'Gebot muss zwischen 0 und deinem Restbudget (70) liegen.', 'FAAB-Antrag über dem Restbudget wird abgelehnt');
update leagues set waiver_mode = 'priority' where id = league();
insert into waiver_claims (league_id,manager_id,add_rider,bid)
values (league(),manager(1),rider(8),999), (league(),manager(2),rider(8),1);
select _process_waivers(matchday());
select ok(exists (select 1 from roster_entries where manager_id = manager(2) and rider_slug = rider(8) and released_on is null), 'Prioritätsmodus folgt der Reihenfolge statt dem Gebot');
select is((select budget_left from managers where id = manager(2)), 50, 'Prioritätsmodus zieht kein zusätzliches Budget ab');

select * from finish();
rollback;
