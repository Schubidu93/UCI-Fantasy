-- =====================================================================
-- Zeitplaner (pg_cron): startet die GitHub-Abläufe zu deutschen Uhrzeiten
-- Der GitHub-Schlüssel liegt verschlüsselt im Supabase Vault ("github_dispatch_token").
-- =====================================================================

do $$ begin
  create extension if not exists pg_net with schema extensions;
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_net/pg_cron nicht verfügbar: %', sqlerrm;   -- z. B. lokale Testdatenbank
end $$;

create or replace function dispatch_workflow(p_file text, p_inputs jsonb default '{}') returns bigint
language plpgsql security definer set search_path = public, extensions as $$
declare v_token text; v_id bigint;
begin
  select decrypted_secret into v_token from vault.decrypted_secrets where name = 'github_dispatch_token';
  if v_token is null then
    raise warning 'Kein github_dispatch_token im Vault – Ablauf % nicht gestartet', p_file;
    return null;
  end if;
  select net.http_post(
    url := 'https://api.github.com/repos/Schubidu93/UCI-Fantasy/actions/workflows/' || p_file || '/dispatches',
    body := jsonb_build_object('ref', 'main', 'inputs', coalesce(p_inputs, '{}'::jsonb)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', 'uci-fantasy-scheduler',
                                  'Content-Type', 'application/json')) into v_id;
  return v_id;
end $$;

