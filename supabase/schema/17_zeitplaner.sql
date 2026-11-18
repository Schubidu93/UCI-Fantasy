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
    url := 'https://api.github.com/repos/' || _app('repo') || '/actions/workflows/' || p_file || '/dispatches',
    body := jsonb_build_object('ref', 'main', 'inputs', coalesce(p_inputs, '{}'::jsonb)),
    headers := jsonb_build_object('Authorization', 'Bearer ' || v_token, 'Accept', 'application/vnd.github+json',
                                  'X-GitHub-Api-Version', '2022-11-28', 'User-Agent', _app('slug') || '-scheduler',
                                  'Content-Type', 'application/json')) into v_id;
  return v_id;
end $$;

-- ---- Feedback ---------------------------------------------------------------------------
-- Nutzer schicken Text und Bilder; der Ablauf "Feedback senden" (feedback.yml) mailt sie an den Betreiber.
-- Bilder liegen nur bis zum Versand in der Datenbank.
create table if not exists feedback (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete set null,
  user_email text,
  league_id  uuid references leagues (id) on delete set null,
  league_name text,
  team_name  text,
  page       text,
  device     text,
  message    text not null,
  attempts   int  not null default 0,
  sent_at    timestamptz,
  created_at timestamptz not null default now()
);
create table if not exists feedback_images (
  id          bigint generated always as identity primary key,
  feedback_id bigint not null references feedback (id) on delete cascade,
  mime        text not null,
  data        bytea not null
);
alter table feedback enable row level security;
alter table feedback_images enable row level security;   -- nur der Service-Key liest (Versand)

-- p_images: [{"mime": "image/jpeg", "data": "<base64>"}, …] (höchstens 5, je höchstens 2 MB)
drop function if exists submit_feedback(text, uuid, text, text, jsonb);
create or replace function submit_feedback(p_message text, p_league uuid, p_page text, p_device text, p_images jsonb default '[]')
returns bigint language plpgsql security definer set search_path = public, extensions as $$
declare v_id bigint; v_img jsonb; v_data bytea;
begin
  if auth.uid() is null then raise exception 'Bitte zuerst anmelden.'; end if;
  if coalesce(btrim(p_message), '') = '' and jsonb_array_length(coalesce(p_images, '[]')) = 0 then
    raise exception 'Bitte schreib etwas oder hänge ein Bild an.';
  end if;
  if length(p_message) > 5000 then raise exception 'Der Text ist zu lang (max. 5000 Zeichen).'; end if;
  if jsonb_array_length(coalesce(p_images, '[]')) > 5 then raise exception 'Höchstens 5 Bilder.'; end if;
  if (select count(*) from feedback where user_id = auth.uid() and created_at > now() - interval '1 day') >= 20 then
    raise exception 'Heute wurde schon sehr viel Feedback geschickt – bitte morgen wieder.';
  end if;
  insert into feedback (user_id, user_email, league_id, league_name, team_name, page, device, message)
  values (auth.uid(), (select email from auth.users where id = auth.uid()), p_league,
          (select name from leagues where id = p_league and is_member(id)),
          (select team_name from managers where league_id = p_league and user_id = auth.uid()),
          left(p_page, 200), left(p_device, 300), coalesce(btrim(p_message), ''))
  returning id into v_id;
  for v_img in select * from jsonb_array_elements(coalesce(p_images, '[]')) loop
    if coalesce(v_img->>'mime', '') not in ('image/jpeg', 'image/png', 'image/webp') then raise exception 'Nur Bilder (JPG, PNG).'; end if;
    v_data := decode(v_img->>'data', 'base64');
    if length(v_data) > 2 * 1024 * 1024 then raise exception 'Ein Bild ist zu groß (max. 2 MB).'; end if;
    insert into feedback_images (feedback_id, mime, data) values (v_id, v_img->>'mime', v_data);
  end loop;
  begin
    perform dispatch_workflow('feedback.yml');
  exception when others then null;    -- ohne Token: Versand beim nächsten Zeitplaner-Lauf
  end;
  return v_id;
end $$;

-- läuft alle 15 Minuten
-- Wochen-Zusammenfassung (montags): Punkte der letzten 7 Tage, Tabellenplatz, bester Fahrer – je Manager mit Push
-- Draft-Report: bestmögliche Punkte jedes Kaders im Vorjahr – je Spieltag (Zeitraum ein Jahr früher) die besten
-- x der y gedrafteten Fahrer (x = wertende Fahrer laut Einstellung, y = Kadergröße). Ergebnis wird zwischengespeichert.
create table if not exists draft_projection (
  league_id  uuid not null references leagues (id) on delete cascade,
  manager_id uuid not null references managers (id) on delete cascade,
  points     numeric not null,
  per_md     jsonb not null default '{}',
  signature  text not null,          -- Spieltage + Wertungsmodus; ändert sich etwas, wird neu gerechnet
  computed_at timestamptz not null default now(),
  primary key (league_id, manager_id)
);
alter table draft_projection enable row level security;
drop policy if exists draft_projection_read on draft_projection;
create policy draft_projection_read on draft_projection for select using (is_member(league_id));

create or replace function draft_projection(p_league uuid)
returns table (manager_id uuid, points numeric, per_md jsonb)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare l leagues; v_x int; v_sig text;
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  select * into l from leagues where id = p_league;
  v_x := case when l.scoring_mode = 'lineup' then coalesce(l.lineup_size, l.roster_size) else l.roster_size end;
  v_sig := v_x || '|' || coalesce((select string_agg(starts_on || '-' || ends_on, ',' order by starts_on)
                                   from matchdays where league_id = p_league), 'jahr')
           || '|' || (select count(*) from draft_lots dl where dl.league_id = p_league and dl.manager_id is not null);
  if not exists (select 1 from draft_projection d where d.league_id = p_league and d.signature = v_sig) then
    delete from draft_projection d where d.league_id = p_league;
    insert into draft_projection (league_id, manager_id, points, per_md, signature)
    with team as (
      select distinct d.manager_id, d.athlete_id from draft_lots d where d.league_id = p_league and d.manager_id is not null),
    mds as (   -- Spieltage ein Jahr früher; ohne Spieltage: die ganze Vorsaison als ein Block
      select m.name, (m.starts_on - interval '1 year')::date s, (m.ends_on - interval '1 year')::date e
        from matchdays m where m.league_id = p_league
      union all
      select 'Vorjahr', make_date(extract(year from l.season_start)::int - 1, 1, 1), make_date(extract(year from l.season_start)::int - 1, 12, 31)
       where not exists (select 1 from matchdays where league_id = p_league)),
    rp as (
      select t.manager_id, md.name, t.athlete_id, sum(r.points) p
        from team t cross join mds md
        join results r on r.athlete_id = t.athlete_id and r.result_date between md.s and md.e
       group by 1, 2, 3),
    best as (
      select rp.manager_id, rp.name, sum(rp.p) p from (
        select rp.*, row_number() over (partition by rp.manager_id, rp.name order by rp.p desc) rn from rp) rp
       where rn <= v_x group by 1, 2)
    select p_league, mg.id, coalesce(sum(b.p), 0), coalesce(jsonb_object_agg(b.name, round(b.p, _pts_digits())) filter (where b.name is not null), '{}'), v_sig
      from managers mg left join best b on b.manager_id = mg.id
     where mg.league_id = p_league group by mg.id;
  end if;
  return query select d.manager_id, d.points, d.per_md from draft_projection d where d.league_id = p_league;
end $$;

create or replace function weekly_summary() returns int
language plpgsql security definer set search_path = public as $$
declare lg leagues; n int := 0; k int;
begin
  for lg in select * from leagues where status = 'active' loop
    with week as (
      select s.manager_id, s.athlete_id, sum(s.points) pts
        from _score_rows(lg.id) s where s.result_date > current_date - 7 group by 1, 2),
    per_mgr as (
      select manager_id, sum(pts) total,
             (array_agg(athlete_id order by pts desc))[1] best_rider, max(pts) best_pts
        from week group by 1)
    insert into notifications (user_id, title, body, url)
    select m.user_id,
           '📊 Deine Woche: +' || _fmt_pts(p.total) || ' Punkte',
           lg.name || ': Platz ' || t."position" || ' von ' || (select count(*) from managers where league_id = lg.id)
             || coalesce(' · bester ' || _word('one') || ' ' || _rname(p.best_rider) || ' (+' || _fmt_pts(p.best_pts) || ')', ' · diese Woche keine Punkte'),
           '#/league/' || lg.id || '/home'
      from managers m
      join _league_table(lg.id) t on t.manager_id = m.id
      left join per_mgr p on p.manager_id = m.id
     where m.league_id = lg.id and m.user_id is not null
       and exists (select 1 from push_subscriptions x where x.user_id = m.user_id)
       -- nur während der Saison mit laufendem oder gerade beendetem Spieltag
       and exists (select 1 from matchdays md where md.league_id = lg.id
                     and md.starts_on <= current_date and md.ends_on >= current_date - 7);
    get diagnostics k = row_count;
    n := n + k;
  end loop;
  return n;
end $$;

create or replace function scheduler_tick() returns void
language plpgsql security definer set search_path = public as $$
declare t timestamp := now() at time zone 'Europe/Berlin';
        h int := extract(hour from t); m int := extract(minute from t);
begin
  begin
    perform process_due(null);                     -- Stichtage (Waiver, Tausch) pünktlich abarbeiten
  exception when others then raise warning 'process_due: %', sqlerrm;
  end;
  if m < 15 then
    perform _sport_tick(h);                        -- Datenabruf der Sportart (02_sportart.sql)
    if h = 9 and extract(isodow from t) = 1 then perform weekly_summary(); end if;   -- Wochen-Zusammenfassung (Mo)
  end if;
  if exists (select 1 from notifications where sent_at is null) then
    perform dispatch_workflow('push.yml');
  end if;
  -- Feedback, das noch nicht verschickt ist (höchstens 3 Versuche, z. B. solange der Mailzugang fehlt)
  if exists (select 1 from feedback where sent_at is null and attempts < 3 and created_at < now() - interval '5 minutes') then
    perform dispatch_workflow('feedback.yml');
  end if;
end $$;

do $$ begin
  perform cron.schedule(_app('slug') || '-tick', '*/15 * * * *', 'select public.scheduler_tick()');
exception when others then raise notice 'Zeitplan nicht angelegt: %', sqlerrm;
end $$;
