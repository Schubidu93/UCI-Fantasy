\ir fixtures.sql
insert into matchdays (id, league_id, name, starts_on, ends_on, deadline, waiver_deadline)
values (test_support.matchday(), test_support.league(), 'Eigene Fristen', current_date + 100, current_date + 110,
        (current_date + 99 + time '13:00') at time zone 'Europe/Berlin',
        (current_date + 97 + time '12:00') at time zone 'Europe/Berlin');
