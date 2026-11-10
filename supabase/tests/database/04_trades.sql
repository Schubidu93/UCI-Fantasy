begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(12);

select login(1);
select throws_ok($$select propose_trade(league(),manager(2),array[rider(4)],array[rider(3)])$$,
  'P0001', 'Die Fahrer müssen in den jeweiligen Kadern stehen.', 'Fremder Fahrer kann nicht angeboten werden');
create temp table trade_fixture (id uuid);
select lives_ok($$insert into trade_fixture select propose_trade(league(),manager(2),array[rider(1)],array[rider(3)])$$,
  'Gültiges Angebot wird angelegt');
select throws_ok($$select respond_trade((select id from trade_fixture),true)$$,
  'P0001', 'Dieses Angebot ist nicht an dich.', 'Anbieter kann das Angebot nicht selbst annehmen');
select is((select status from trades where id = (select id from trade_fixture)), 'proposed', 'Abgelehnte Annahme verändert das Angebot nicht');
select login(2);
select lives_ok($$select respond_trade((select id from trade_fixture),true)$$, 'Empfänger kann das Angebot annehmen');
select is((select status from trades where id = (select id from trade_fixture)), 'accepted', 'Angenommener Tausch wartet auf den Stichtag');
insert into matchdays (id,league_id,name,starts_on,ends_on,deadline)
values (matchday(),league(),'Tausch-Test',current_date + 3,current_date + 10,now() + interval '23 hours');
select _process_trades(matchday());
select is((select status from trades where id = (select id from trade_fixture)), 'accepted', 'Tausch wird vor Ablauf der Vetofrist nicht ausgeführt');
update matchdays set deadline = now() + interval '25 hours' where id = matchday();
select _process_trades(matchday());
select is((select status from trades where id = (select id from trade_fixture)), 'done', 'Tausch nach der Vetofrist wird ausgeführt');
select ok(exists (select 1 from roster_entries where manager_id = manager(2) and rider_slug = rider(1) and released_on is null)
      and exists (select 1 from roster_entries where manager_id = manager(1) and rider_slug = rider(3) and released_on is null), 'Beide Fahrer wechseln den Besitzer');
select is((select released_on from roster_entries where manager_id = manager(1) and rider_slug = rider(1)), current_date + 3, 'Alte Zugehörigkeit endet am Spieltagstart');
select _process_trades(matchday());
select is((select count(*)::int from roster_entries where league_id = league()), 6, 'Erneute Verarbeitung legt keine doppelten Kaderzeilen an');
select throws_ok($$select veto_trade((select id from trade_fixture))$$,
  'P0001', 'Nur der Liga-Admin darf das.', 'Ein normales Mitglied besitzt kein Admin-Veto');

select * from finish();
rollback;
