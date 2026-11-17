begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(9);

insert into matchdays (id,league_id,name,starts_on,ends_on,deadline,status,waivers_done,locked,closed_at)
values (matchday(),league(),'Wertung',current_date - 10,current_date - 1,now() - interval '11 days',
        'closed',true,true,now() - interval '8 days');
update roster_entries set acquired_on = current_date - 5, released_on = current_date - 2
 where manager_id = manager(1) and rider_slug = rider(1);
insert into results (rider_slug,race_slug,label,result_date,uci_points)
values (rider(1),'test-race','before',current_date - 6,100),
       (rider(1),'test-race','acquired',current_date - 5,10),
       (rider(1),'test-race','during',current_date - 3,20),
       (rider(1),'test-race','released',current_date - 2,100),
       (rider(2),'test-race','other',current_date - 4,5),
       (rider(3),'test-race','opponent',current_date - 4,35);
select is((select sum(points) from _league_points(league()) where manager_id = manager(1)), 35::numeric,
  'Wertung zählt Erwerbstag einschließlich und Abgabetag ausschließlich');
select is((select count(*)::int from _score_rows(league()) where rider_slug = rider(1)), 2,
  'Ergebnisse vor Erwerb und ab Abgabe werden ausgeschlossen');
select is((select "position" from _league_table(league()) where manager_id = manager(2)), 1,
  'Bei gleichem Punktestand entscheidet zuletzt das geringere ausgegebene Budget');
update matchdays set scoring_mode = 'lineup', lineup_size = 1 where id = matchday();
insert into lineups values (matchday(),manager(1),rider(2));
select is((select sum(points) from _league_points(league()) where manager_id = manager(1)), 5::numeric,
  'Aufstellungsmodus zählt nur aufgestellte Fahrer');
select login(1);
select admin_set_override(league(),matchday(),manager(1),rider(2),7,'Testkorrektur');
select is((select sum(points) from _league_points(league()) where manager_id = manager(1)), 7::numeric,
  'Admin-Korrektur ersetzt Fahrerpunktzahl statt sie zu addieren');
delete from point_overrides;
update matchdays set scoring_mode = 'full' where id = matchday();
select run_maintenance();
select ok((select frozen from matchdays where id = matchday()), 'Abgeschlossener Spieltag wird nach sieben Tagen eingefroren');
update results set uci_points = 999;
select is((select sum(points) from _league_points(league()) where manager_id = manager(1)), 35::numeric,
  'Spätere Ergebnisänderungen verändern eingefrorene Punkte nicht');
select is((select sum(points) from _score_rows(league())), 70::numeric, 'Eingefrorene Einzelergebnisse bleiben vollständig');
select admin_set_override(league(),matchday(),manager(1),rider(2),7,'Korrektur nach Einfrieren');
select is((select sum(points) from _league_points(league()) where manager_id = manager(1)), 37::numeric,
  'Explizite Admin-Korrektur bleibt auch nach dem Einfrieren wirksam');

select * from finish();
rollback;
