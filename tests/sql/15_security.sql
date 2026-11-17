begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Sicherheit: interne Funktionen gesperrt, Zeilenschutz auf allen Tabellen, Abmeldung
select is((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like '\_%' and has_function_privilege('authenticated', p.oid, 'execute')),
          null, 'Interne Funktionen (_…) sind für angemeldete Nutzer gesperrt');
select is((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('run_maintenance', 'notify_new_points', 'scheduler_tick', 'dispatch_workflow', 'weekly_summary', 'refresh_season_stats')
              and has_function_privilege('authenticated', p.oid, 'execute')),
          null, 'Zeitplaner- und Wartungsfunktionen sind für Nutzer gesperrt');
select is((select string_agg(tablename, ', ') from pg_tables where schemaname = 'public' and not rowsecurity), null, 'Alle Tabellen haben Zeilenschutz (RLS)');
select is((select string_agg(p.oid::regprocedure::text, ', ') from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.prosecdef and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
          null, 'Alle security-definer-Funktionen setzen einen festen search_path');
-- nicht angemeldet
select set_config('request.jwt.claim.sub', '', true);   -- abgemeldet
select throws_ok($$select create_league('X', 'Y', '{}')$$, null, null, 'Ohne Anmeldung keine Liga');
select throws_ok($$select join_league((select invite_code from leagues where id = league()), 'X')$$, 'P0001', 'Bitte zuerst anmelden.', 'Ohne Anmeldung kein Beitritt');
-- fremde Liga
select login(3);
select throws_ok($$select submit_waiver(league(), rider(5), null)$$, null, null, 'Waiver nur in der eigenen Liga');
select throws_ok($$select propose_trade(league(), manager(2), array[rider(1)], array[rider(3)])$$, null, null, 'Tausch nur in der eigenen Liga');
select throws_ok($$select upsert_matchday(league(), null, 'X', current_date + 5, current_date + 9)$$, 'P0001', 'Nur der Liga-Admin darf das.', 'Spieltage nur durch den Admin');
select * from finish();
rollback;
