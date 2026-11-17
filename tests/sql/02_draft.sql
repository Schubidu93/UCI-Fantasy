begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
select plan(15);

delete from roster_entries where league_id = league();
update leagues set status = 'setup' where id = league();
select login(1);
select lives_ok($$select start_draft(league())$$, 'Admin kann den Draft starten');
select is((select status from draft_state where league_id = league()), 'running', 'Draft läuft');
select is((select current_rider from draft_state where league_id = league()), rider(1), 'Ranglisten-Draft beginnt beim bestplatzierten Fahrer');
select throws_ok($$select draft_bid(league(),97)$$, 'P0001', 'Dein Höchstgebot ist 96.', 'Gebot darf Budgetreserve nicht verbrauchen');
select is((select count(*)::int from draft_bids where league_id = league()), 0, 'Abgelehntes Gebot hinterlässt keinen Eintrag');
select lives_ok($$select draft_bid(league(),10)$$, 'Gültiges Gebot wird angenommen');
select is((select current_bid from draft_state where league_id = league()), 10, 'Aktuelles Gebot wird gespeichert');
select is((select budget_left from managers where id = manager(1)), 100, 'Budget wird erst beim Zuschlag abgezogen');
select throws_ok($$select draft_bid(league(),11)$$, 'P0001', 'Du bist schon Höchstbietender.', 'Höchstbietender kann sich nicht selbst überbieten');
select login(2);
select throws_ok($$select draft_bid(league(),10)$$, 'P0001', 'Gebot muss mindestens 11 sein.', 'Ein gleich hohes Gebot genügt nicht');
update draft_state set deadline = now() - interval '1 second' where league_id = league();
select lives_ok($$select draft_tick(league())$$, 'Abgelaufene Auktion wird abgewickelt');
select is((select budget_left from managers where id = manager(1)), 90, 'Zuschlag zieht genau den Kaufpreis ab');
select ok(exists (select 1 from roster_entries where manager_id = manager(1) and rider_slug = rider(1) and price = 10), 'Gewinner erhält den Fahrer zum Gebotspreis');
select lives_ok($$select draft_tick(league())$$, 'Weiterer Tick vor Ablauf der nächsten Uhr bleibt folgenlos');
select is((select count(*)::int from draft_lots where league_id = league()), 1, 'Zuschlag wird nur einmal protokolliert');

select * from finish();
rollback;
