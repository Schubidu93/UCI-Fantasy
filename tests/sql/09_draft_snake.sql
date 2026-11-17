begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Snake-Draft: Reihenfolge, falscher Manager, vergebene Fahrer, automatische Wahl bei Zeitablauf, Draft-Ende
delete from roster_entries where league_id = league();
update leagues set status = 'setup', draft_mode = 'snake', roster_size = 5 where id = league();
select login(1);
select lives_ok($$select start_draft(league())$$, 'Admin startet den Snake-Draft');
select is((select phase from draft_state where league_id = league()), 'snake', 'Draft läuft im Snake-Modus');
-- Admin-Rechte kurz an jemand außerhalb geben, damit beide Manager normale Mitspieler sind
update leagues set admin_user = user_id(3) where id = league();
create temp table turn as select nominator m1, (select user_id from managers where id = nominator) u1,
  (select user_id from managers where league_id = league() and id <> nominator) u2 from draft_state where league_id = league();
select set_config('request.jwt.claim.sub', (select u2::text from turn), true);
select throws_ok($$select draft_snake_pick(league(), rider(5))$$, 'P0001', 'Du bist nicht an der Reihe.', 'Wer nicht dran ist, kann nicht wählen');
select set_config('request.jwt.claim.sub', (select u1::text from turn), true);
select lives_ok($$select draft_snake_pick(league(), rider(5))$$, 'Wer dran ist, wählt einen Fahrer');
select ok(exists (select 1 from roster_entries where manager_id = (select m1 from turn) and rider_slug = rider(5)), 'Gewählter Fahrer steht im Kader');
select ok((select nominator from draft_state where league_id = league()) <> (select m1 from turn), 'Danach ist der andere Manager dran');
select set_config('request.jwt.claim.sub', (select u2::text from turn), true);
select throws_ok($$select draft_snake_pick(league(), rider(5))$$, 'P0001', 'Dieser Fahrer ist nicht verfügbar.', 'Vergebener Fahrer kann nicht erneut gewählt werden');
-- restliche Wahlen per Zeitablauf (automatisch der beste freie Fahrer)
select login(1);
do $$ begin
  for i in 1..20 loop
    exit when (select status from draft_state where league_id = test_support.league()) <> 'running';
    update draft_state set deadline = now() - interval '1 second' where league_id = test_support.league();
    perform draft_tick(test_support.league());
  end loop;
end $$;
select is((select count(*)::int from roster_entries where league_id = league()), 10, 'Beide Kader sind voll (je 5)');
select is((select array_agg(rider_slug order by rider_slug) from roster_entries where league_id = league()),
  (select array_agg(rider(n) order by rider(n)) from unnest(array[1,2,3,4,5,6,7,8,9,10]) n), 'Automatische Wahl nimmt die bestplatzierten freien Fahrer');
select is((select manager_id from draft_lots where league_id = league() and lot_no = 2), (select manager_id from draft_lots where league_id = league() and lot_no = 3),
  'Snake: wer als Zweiter wählt, wählt auch als Dritter');
select is((select status from draft_state where league_id = league()), 'done', 'Draft ist beendet');
select is((select status from leagues where id = league()), 'active', 'Liga ist nach dem Draft aktiv');
select * from finish();
rollback;
