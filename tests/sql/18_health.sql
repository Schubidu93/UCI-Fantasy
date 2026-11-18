begin;
set local search_path = public, extensions, test_support;
\ir ../support/fixtures.sql
-- Gesundheitscheck (_health_check): meldet Probleme als Text, bei frischen Daten nur das, was es lokal nicht gibt
update sync_status set last_run = now(), ok = true where id = 1;
update athletes set updated_at = now();
create temp table hc as select * from _health_check() p;
select ok(exists (select 1 from hc where p like 'Zeitplaner%'), 'Ohne pg_cron meldet der Check den Zeitplaner');
select ok(not exists (select 1 from hc where p like 'Datenabruf%' or p like 'Personenliste%' or p like 'Push%' or p like 'Liga%'),
          'Frische Daten und funktionierende Ligen: keine weiteren Meldungen');
-- veraltete Daten, hängende Push-Nachricht, gescheiterte Feedback-Mail
update sync_status set last_run = now() - interval '30 days' where id = 1;
update athletes set updated_at = now() - interval '3 days';
insert into notifications (user_id, title, created_at) values (user_id(1), 'alt', now() - interval '5 hours');
insert into feedback (message, attempts) values ('Test', 3);
truncate hc; insert into hc select * from _health_check();
select ok(exists (select 1 from hc where p like 'Datenabruf%'), 'Veralteter Datenabruf wird gemeldet');
select ok(exists (select 1 from hc where p like 'Personenliste%'), 'Veraltete Personenliste wird gemeldet');
select ok(exists (select 1 from hc where p like 'Push%'), 'Nicht verschickte Push-Nachricht wird gemeldet');
select ok(exists (select 1 from hc where p like 'Feedback%'), 'Gescheiterte Feedback-Mail wird gemeldet');
select * from finish();
rollback;
