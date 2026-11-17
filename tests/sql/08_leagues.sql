begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Liga anlegen, beitreten, Einstellungen, Admin-Rechte
insert into auth.users (id, email) select user_id(n), 'user' || n || '@example.invalid' from generate_series(4, 6) n;
create temp table nl (id uuid, code text);
select login(4);
select lives_ok($$insert into nl (id) select create_league('Neue Liga', 'Team Vier', '{"max_managers": 2}')$$, 'Angemeldeter Nutzer legt eine Liga an');
update nl set code = (select invite_code from leagues where id = nl.id);
select is((select status from leagues where id = (select id from nl)), 'setup', 'Neue Liga beginnt in der Vorbereitung');
select ok(is_admin((select id from nl)), 'Ersteller ist Admin');
select is((select count(*)::int from managers where league_id = (select id from nl)), 1, 'Ersteller ist der erste Manager');
select is(league_by_code((select code from nl))->>'name', 'Neue Liga', 'Einladungscode findet die Liga');
select login(5);
select lives_ok($$select join_league((select code from nl), 'Team Fünf')$$, 'Zweiter Nutzer tritt per Code bei');
select is(join_league((select code from nl), 'Nochmal'), (select id from nl), 'Erneuter Beitritt führt zur selben Liga');
select is((select count(*)::int from managers where league_id = (select id from nl)), 2, 'Erneuter Beitritt legt keinen zweiten Manager an');
select ok(not is_admin((select id from nl)), 'Beigetretener Nutzer ist kein Admin');
select throws_ok($$select update_league_settings((select id from nl), '{"roster_size": 10}')$$, 'P0001', 'Nur der Liga-Admin darf das.', 'Nur der Admin ändert Einstellungen');
select login(6);
select throws_ok($$select join_league((select code from nl), 'Team Sechs')$$, 'P0001', 'Die Liga ist voll.', 'Volle Liga nimmt niemanden mehr auf');
select throws_ok($$select join_league('falscher-code', 'X')$$, 'P0001', 'Einladungslink ungültig.', 'Falscher Einladungscode wird abgelehnt');
select login(4);
select lives_ok($$select update_league_settings((select id from nl), '{"roster_size": 10}')$$, 'Admin ändert die Kadergröße vor dem Draft');
select is((select roster_size from leagues where id = (select id from nl)), 10, 'Neue Kadergröße ist gespeichert');
select throws_ok($$select update_league_settings((select id from nl), '{"max_managers": 1}')$$, '23514', null, 'Eine Liga braucht mindestens zwei Plätze');
select lives_ok($$select set_team_name((select id from nl), 'Umbenannt')$$, 'Teamname ist änderbar');
select is((select team_name from managers where league_id = (select id from nl) and user_id = user_id(4)), 'Umbenannt', 'Neuer Teamname ist gespeichert');
select throws_ok($$select remove_manager((select id from nl), (select id from managers where league_id = (select id from nl) and user_id = user_id(4)))$$,
  'P0001', 'Übertrage zuerst die Admin-Rechte.', 'Admin kann sich nicht selbst entfernen');
select lives_ok($$select transfer_admin((select id from nl), (select id from managers where league_id = (select id from nl) and user_id = user_id(5)))$$, 'Admin-Rechte werden übertragen');
select ok(not is_admin((select id from nl)), 'Bisheriger Admin ist kein Admin mehr');
select login(5);
select ok(is_admin((select id from nl)), 'Neuer Admin hat die Rechte');
-- nach dem Draft (Liga A ist aktiv)
select login(1);
select throws_ok($$select update_league_settings(league(), '{"roster_size": 10}')$$, 'P0001', 'Diese Einstellung ist nach dem Draft nicht mehr änderbar.', 'Kadergröße ist nach dem Draft gesperrt');
select lives_ok($$select update_league_settings(league(), '{"waiver_mode": "faab"}')$$, 'Waiver-Art bleibt nach dem Draft änderbar');
select is((select waiver_mode from leagues where id = league()), 'faab', 'Neue Waiver-Art ist gespeichert');
select login(3);
select throws_ok($$select join_league((select invite_code from leagues where id = league()), 'Zu spät')$$, 'P0001',
  'Der Draft hat schon begonnen. Übernimm einen freien Platz.', 'Nach dem Draft ist kein normaler Beitritt möglich');
select * from finish();
rollback;
