begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Neue Saison: Liga kopieren übernimmt alle Einstellungen, setzt Zustand und Saison neu; Keeper
update leagues set bid_seconds = 20, roster_size = 7, max_managers = 6, transfer_mode = 'waiver', waiver_mode = 'faab', max_per_team = 3
 where id = league();
create temp table nl (id uuid);
select login(2);
select throws_ok($$select copy_league(league(), 'Saison 2', current_date + 200, current_date + 500)$$, 'P0001',
  'Nur der Liga-Admin darf das.', 'Nur der Admin legt die neue Saison an');
select login(1);
select lives_ok($$insert into nl select copy_league(league(), 'Saison 2', current_date + 200, current_date + 500, 2, 10)$$,
  'Admin legt die neue Saison an');
select is((select to_jsonb(n) - array['id', 'invite_code', 'created_at', 'name', 'season_start', 'season_end', 'prev_league',
                                       'keeper_count', 'keeper_surcharge', 'status', 'last_waiver_run', 'draft_at']
             from leagues n where n.id = (select id from nl)),
          (select to_jsonb(o) - array['id', 'invite_code', 'created_at', 'name', 'season_start', 'season_end', 'prev_league',
                                       'keeper_count', 'keeper_surcharge', 'status', 'last_waiver_run', 'draft_at']
             from leagues o where o.id = league()),
          'Alle Einstellungen (Gebote, Tausch, Waiver, Kader …) werden übernommen');
select is((select (name, status, prev_league, keeper_count, keeper_surcharge, season_start)::text from leagues where id = (select id from nl)),
          ('Saison 2', 'setup', league(), 2, 10, current_date + 200)::text, 'Name, Saison, Keeper-Regeln neu; Liga in Vorbereitung');
select ok((select invite_code from leagues where id = (select id from nl)) <> (select invite_code from leagues where id = league()),
          'Neuer Einladungscode');
select is((select count(*)::int from managers where league_id = (select id from nl)),
          (select count(*)::int from managers where league_id = league()), 'Alle Manager sind dabei');
select is((select count(*)::int from managers n join managers o on o.id = n.prev_manager
            where n.league_id = (select id from nl) and o.user_id is not distinct from n.user_id),
          (select count(*)::int from managers where league_id = league()), 'Manager sind mit der Vorsaison verknüpft');
select ok(exists (select 1 from draft_state where league_id = (select id from nl)), 'Draft ist vorbereitet');
select * from finish();
rollback;
