-- =====================================================================
-- Offline-Draft-Import
-- p_rows: [{"manager_id": "...", "rider_slug": "...", "price": 12}, …]
-- Gibt eine Liste von Fehlern zurück; nur ohne Fehler und mit p_commit wird gespeichert.
-- =====================================================================

create or replace function import_offline_draft(p_league uuid, p_rows jsonb, p_commit boolean default false)
returns text[] language plpgsql security definer set search_path = public as $$
declare l leagues; errs text[] := '{}'; r record;
begin
  perform _require_admin(p_league);
  select * into l from leagues where id = p_league for update;
  if l.status <> 'setup' then return array['Die Kader sind bereits fixiert.']; end if;

  create temp table _imp on commit drop as
    select (e->>'manager_id')::uuid manager_id, e->>'rider_slug' rider_slug,
           coalesce(nullif(e->>'price', '')::int, 0) price
      from jsonb_array_elements(p_rows) e;

  for r in select i.manager_id from _imp i where not exists (select 1 from managers m where m.id = i.manager_id and m.league_id = p_league) group by 1 loop
    errs := errs || format('Unbekannter Manager %s', r.manager_id);
  end loop;
  for r in select i.rider_slug from _imp i where not exists (select 1 from riders x where x.pcs_slug = i.rider_slug and x.gender = l.gender) loop
    errs := errs || format('Fahrer %s nicht im UCI-Ranking gefunden', r.rider_slug);
  end loop;
  for r in select rider_slug from _imp group by 1 having count(*) > 1 loop
    errs := errs || format('Fahrer %s ist mehrfach vergeben', r.rider_slug);
  end loop;
  for r in select m.team_name, count(i.rider_slug) n, coalesce(sum(i.price), 0) s
             from managers m left join _imp i on i.manager_id = m.id
            where m.league_id = p_league group by m.id, m.team_name loop
    if r.n <> l.roster_size then errs := errs || format('%s: %s statt %s Fahrer', r.team_name, r.n, l.roster_size); end if;
    if r.s > l.budget then errs := errs || format('%s: Summe %s über Budget %s', r.team_name, r.s, l.budget); end if;
  end loop;
  for r in select * from _imp where price < 0 loop
    errs := errs || format('Negativer Preis bei %s', r.rider_slug);
  end loop;
  if l.max_per_team is not null then
    for r in select m.team_name, x.team, count(*) n from _imp i join riders x on x.pcs_slug = i.rider_slug
               join managers m on m.id = i.manager_id where x.team is not null
              group by m.team_name, x.team having count(*) > l.max_per_team loop
      errs := errs || format('%s: %s Fahrer von %s (max. %s)', r.team_name, r.n, r.team, l.max_per_team);
    end loop;
  end if;

  if array_length(errs, 1) is null and p_commit then
    insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
      select p_league, manager_id, rider_slug, price, 'offline', l.season_start from _imp;
    update managers m set budget_left = l.budget - coalesce((select sum(price) from _imp i where i.manager_id = m.id), 0),
           draft_position = s.rn
      from (select id, row_number() over (order by random()) rn from managers where league_id = p_league) s
     where m.id = s.id;
    insert into draft_state (league_id) values (p_league) on conflict (league_id) do nothing;
    update draft_state set status = 'done' where league_id = p_league;
    update leagues set status = 'active', last_waiver_run = now() where id = p_league;
    perform _log(p_league, 'offline_import', jsonb_build_object('rows', jsonb_array_length(p_rows)));
  end if;
  drop table _imp;
  return errs;
end $$;

