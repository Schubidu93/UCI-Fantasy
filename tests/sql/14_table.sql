begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Tabelle: Gleichstand nach Spieltagssiegen und bestem Spieltag; Waiver-Reihenfolge
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline, status, waivers_done, locked)
values (matchday(1), league(), 'S1', current_date - 20, current_date - 15, now() - interval '21 days', 'closed', true, true),
       (matchday(2), league(), 'S2', current_date - 10, current_date - 5, now() - interval '11 days', 'closed', true, true);
insert into results (athlete_id, competition_id, label, result_date, points)
values (rider(1), 'r1', 'a', current_date - 18, 30),   -- S1: A 30, B 10 → Sieg A
       (rider(3), 'r1', 'b', current_date - 18, 10),
       (rider(3), 'r2', 'c', current_date - 8, 12),    -- S2: B 20, A 0 → Sieg B
       (rider(4), 'r2', 'd', current_date - 8, 8);
select is((select array_agg(total order by manager_id) from _league_table(league())), array[30, 30]::numeric[], 'Gleichstand bei den Punkten');
select is((select "position" from _league_table(league()) where manager_id = manager(1)), 1, 'Bei Gleichstand gewinnt der bessere Einzelspieltag (30 vor 20)');
select is((select array_agg(matchday_wins order by manager_id) from _league_table(league())), array[1, 1], 'Jeder hat einen Spieltagssieg');
select is((select manager_id from _waiver_order(league()) where waiver_pos = 1), manager(2), 'Waiver: Tabellenletzter ist zuerst dran');
insert into results (athlete_id, competition_id, label, result_date, points) values (rider(2), 'r2', 'e', current_date - 8, 1);
select is((select "position" from _league_table(league()) where manager_id = manager(1)), 1, 'Ein Punkt mehr: A führt allein');
select is((select array_agg(matchday_wins order by manager_id) from _league_table(league())), array[1, 1], 'Spieltagssiege unverändert');
select * from finish();
rollback;
