begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(12);

select is(_open_slots(manager(1)), 3, 'Drei freie Plätze bei zwei von fünf Fahrern');
select is(_open_roster_slots(manager(1)), 3, 'Beide Kaderplatz-Helfer liefern denselben Stand');
select is(_max_bid(manager(1)), 68, 'Höchstgebot reserviert je einen Punkt für weitere Plätze');
select throws_ok($$insert into roster_entries (league_id,manager_id,rider_slug,source,acquired_on)
  values (league(),manager(2),rider(1),'admin',current_date)$$,
  '23505', null, 'Ein aktiver Fahrer kann in einer Liga nur einmal vergeben sein');
select lives_ok($$insert into roster_entries (league_id,manager_id,rider_slug,source,acquired_on)
  values (league(2),manager(3),rider(1),'admin',current_date)$$,
  'Derselbe Fahrer darf in einer anderen Liga vergeben sein');
select ok(_release(league(), manager(1), rider(1), current_date), 'Abgabe beendet die aktive Zugehörigkeit');
select is(_open_slots(manager(1)), 4, 'Abgabe schafft einen freien Platz');
select ok(_rider_free(league(), rider(1), 'infinity'), 'Abgegebener Fahrer ist ohne Sperrprüfung frei');
select ok(not _rider_free(league(), rider(1), now() - interval '1 minute'), 'Aktuelle Abgabe bleibt innerhalb der Sperrfrist gesperrt');
select ok(not _release(league(), manager(1), rider(1), current_date), 'Bereits abgegebener Fahrer wird nicht erneut abgegeben');
update leagues set max_per_team = 1 where id = league();
select ok(not _team_limit_ok(manager(1), rider(4)), 'Profiteam-Grenze verhindert einen weiteren Fahrer desselben Teams');
select ok(_team_limit_ok(manager(1), rider(4), rider(2)), 'Austausch innerhalb desselben Profiteams bleibt erlaubt');

select * from finish();
rollback;
