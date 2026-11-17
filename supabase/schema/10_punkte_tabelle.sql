-- =====================================================================
-- Punkte und Tabelle
-- =====================================================================

-- Alle Einzelergebnisse, die in der Liga zählen (eingefroren oder live)
create or replace function _score_rows(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, race_slug text, label text,
               result_date date, points numeric)
language sql stable security definer set search_path = public as $$
  select s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, s.label, s.result_date, s.points
    from score_snapshot s join matchdays m on m.id = s.matchday_id
   where m.league_id = p_league and m.frozen
  union all
  select m.id, re.manager_id, re.rider_slug, r.race_slug, r.label, r.result_date, r.uci_points
    from matchdays m
    join leagues l on l.id = m.league_id
    join roster_entries re on re.league_id = m.league_id
    join results r on r.rider_slug = re.rider_slug
                  and r.result_date between m.starts_on and m.ends_on
                  and r.result_date >= re.acquired_on
                  and (re.released_on is null or r.result_date < re.released_on)
   where m.league_id = p_league and not m.frozen and m.starts_on <= current_date
     and (coalesce(m.scoring_mode, l.scoring_mode) = 'full'
          or re.rider_slug in (select effective_lineup(m.id, re.manager_id)));
$$;

-- Punkte pro Spieltag, Manager und Fahrer (inkl. Admin-Korrekturen)
create or replace function _league_points(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, points numeric, overridden boolean)
language sql stable security definer set search_path = public as $$
  with agg as (
    select s.matchday_id, s.manager_id, s.rider_slug, sum(s.points) pts
      from _score_rows(p_league) s group by 1, 2, 3),
  ov as (select * from point_overrides o where o.league_id = p_league)
  select coalesce(a.matchday_id, ov.matchday_id), coalesce(a.manager_id, ov.manager_id),
         coalesce(a.rider_slug, ov.rider_slug), coalesce(ov.points, a.pts), ov.id is not null
    from agg a full join ov on ov.matchday_id = a.matchday_id and ov.manager_id = a.manager_id
                           and ov.rider_slug = a.rider_slug;
$$;

-- Liga-Tabelle mit Tiebreakern: Punkte, Spieltagssiege, bester Spieltag, weniger Budget ausgegeben
create or replace function _league_table(p_league uuid)
returns table (manager_id uuid, team_name text, total numeric, matchday_wins int, best_matchday numeric,
               spent int, "position" int)
language sql stable security definer set search_path = public as $$
  with lp as (select * from _league_points(p_league)),
  md as (select lp.matchday_id, lp.manager_id, sum(lp.points) p from lp group by 1, 2),
  mx as (select md.matchday_id, max(md.p) m from md group by 1),
  w  as (select md.manager_id, count(*)::int n from md join mx on mx.matchday_id = md.matchday_id
          where md.p = mx.m and mx.m > 0 group by 1),
  sp as (select re.manager_id, sum(re.price)::int s from roster_entries re
          where re.league_id = p_league and re.source in ('draft', 'offline') group by 1),
  t as (
    select m.id, m.team_name, coalesce((select sum(md.p) from md where md.manager_id = m.id), 0) tot,
           coalesce(w.n, 0) wins, coalesce((select max(md.p) from md where md.manager_id = m.id), 0) best,
           coalesce(sp.s, 0) spent
      from managers m left join w on w.manager_id = m.id left join sp on sp.manager_id = m.id
     where m.league_id = p_league)
  select t.id, t.team_name, t.tot, t.wins, t.best, t.spent,
         (rank() over (order by t.tot desc, t.wins desc, t.best desc, t.spent asc))::int
    from t order by 7, 2;
$$;

-- Waiver-Reihenfolge: Tabellenletzter zuerst; solange alle 0 Punkte haben, umgekehrte Draft-Reihenfolge
create or replace function _waiver_order(p_league uuid)
returns table (manager_id uuid, team_name text, waiver_pos int)
language sql stable security definer set search_path = public as $$
  with t as (select * from _league_table(p_league)),
  allzero as (select coalesce(bool_and(t.total = 0), true) z from t)
  select t.manager_id, t.team_name,
         (row_number() over (order by case when (select z from allzero) then 0 else t."position" end desc,
                                      m.draft_position desc nulls last))::int
    from t join managers m on m.id = t.manager_id
   order by 3;
$$;

create or replace function league_points(p_league uuid)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, points numeric, overridden boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_points(p_league);
end $$;

create or replace function league_table(p_league uuid)
returns table (manager_id uuid, team_name text, total numeric, matchday_wins int, best_matchday numeric,
               spent int, "position" int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _league_table(p_league);
end $$;

create or replace function waiver_order(p_league uuid)
returns table (manager_id uuid, team_name text, waiver_pos int)
language plpgsql stable security definer set search_path = public as $$
begin
  if not (is_member(p_league) or _is_service()) then raise exception 'Keine Berechtigung.'; end if;
  return query select * from _waiver_order(p_league);
end $$;

-- Namen vergleichbar machen: 'POGAČAR Tadej' = 'Tadej Pogacar' (Akzente weg, Wörter sortiert)
create extension if not exists unaccent with schema extensions;
create or replace function norm_name(p text) returns text
language sql immutable parallel safe set search_path = public, extensions as $$
  select array_to_string(array(select w from unnest(regexp_split_to_array(
           lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(p, ''))), '[^a-z0-9]+')) w
         where w <> '' order by w), ' ');
$$;
create index if not exists riders_norm_name on riders (gender, norm_name(name));

-- Ergebniszeilen ohne Fahrer-Verknüpfung über den Namen zuordnen (nach Fahrer- oder Rennimport)
-- Punkte aus den Ergebnislisten in die Wertung übernehmen, die dort noch fehlen
-- (z. B. weil der Fahrername erst später einem Fahrer zugeordnet werden konnte).
-- Bezeichnung wie in race_results.py: „Etappe · Wertung“ bzw. nur eins davon.
create or replace function results_from_events() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into results (rider_slug, race_slug, label, result_date, rank, uci_points)
  select er.rider_slug, e.race_slug,
         left(coalesce(nullif(case
           when coalesce(trim(e.stage_name), '') = '' or trim(e.stage_name) = trim(e.event_name) then trim(e.event_name)
           when coalesce(trim(e.event_name), '') = '' then trim(e.stage_name)
           else trim(e.stage_name) || ' · ' || trim(e.event_name) end, ''), 'Ergebnis'), 200),
         e.event_date, er.rank, er.uci_points
    from event_results er join race_events e on e.id = er.event_id
   where er.rider_slug is not null and er.uci_points > 0 and e.event_date >= date '2025-01-01'
     and exists (select 1 from riders x where x.pcs_slug = er.rider_slug)
     -- nicht doppelt zählen: gleiches Ergebnis (Fahrer, Tag, Punkte) schon unter anderem Namen gespeichert
     and not exists (select 1 from results r where r.rider_slug = er.rider_slug and r.result_date = e.event_date
                       and r.uci_points = er.uci_points)
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Schnell auch bei vielen unbekannten Namen: der normalisierte Name der noch nicht verknüpften Zeilen steht
-- in einem Teilindex, gesucht wird von den (wenigen) Fahrern aus.
set statement_timeout = 0;
create index if not exists event_results_unlinked_name on event_results (norm_name(rider_name)) where rider_slug is null;
reset statement_timeout;
create or replace function relink_event_riders() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update event_results er set rider_slug = m.pcs_slug
    from (select distinct on (u.event_id, u.sort_order) u.event_id, u.sort_order, x.pcs_slug
            from riders x
            join event_results u on norm_name(u.rider_name) = norm_name(x.name) and u.rider_slug is null
            join race_events ev on ev.id = u.event_id
            join races ra on ra.pcs_slug = ev.race_slug and ra.gender = x.gender
           order by u.event_id, u.sort_order, x.uci_rank nulls last) m
   where er.event_id = m.event_id and er.sort_order = m.sort_order;
  get diagnostics n = row_count;
  return n;
end $$;

-- UCI-Punkte pro Fahrer in einem Jahr (für die Fahrerliste der App)
create or replace function rider_points(p_gender text, p_year int)
returns table (rider_slug text, points numeric, results int)
language sql stable security definer set search_path = public as $$
  -- Punkte aus Rennen des Kalenderjahres (1.1. bis 31.12.)
  select r.rider_slug, sum(r.uci_points), count(*)::int
    from results r join riders x on x.pcs_slug = r.rider_slug
   where x.gender = p_gender
     and r.result_date >= make_date(p_year, 1, 1) and r.result_date <= make_date(p_year, 12, 31)
   group by r.rider_slug
   order by r.rider_slug;
$$;

-- Punkte der letzten Tage (Standard 30) – für „heiße freie Fahrer“
create or replace function rider_points_recent(p_gender text, p_days int default 30)
returns table (rider_slug text, points numeric, results int)
language sql stable security definer set search_path = public as $$
  select r.rider_slug, sum(r.uci_points), count(*)::int
    from results r join riders x on x.pcs_slug = r.rider_slug
   where x.gender = p_gender and r.result_date > current_date - p_days and r.uci_points > 0
   group by r.rider_slug
   order by r.rider_slug;
$$;

-- ---- Vorläufige Kalendereinträge -----------------------------------------------------------
-- Künftige Rennen, die DataRide noch nicht kennt, kommen aus dem UCI-Wettkampfverzeichnis
-- (datasync/uci_calendar.py, täglich) und werden ersetzt, sobald DataRide das Rennen liefert.
alter table races add column if not exists provisional boolean not null default false;
-- Ländercodes einheitlich wie bei der UCI (IOC): frühere ISO-Codes der vorläufigen Einträge korrigieren
update races set country = case country when 'DEU' then 'GER' when 'NLD' then 'NED' when 'CHE' then 'SUI'
                                        when 'DNK' then 'DEN' when 'ARE' then 'UAE' end
 where country in ('DEU', 'NLD', 'CHE', 'DNK', 'ARE');

-- Einmalig: künftige Spieltage mit dem alten Standard-Stichtag (Start 00:00) auf den neuen (Vortag 20:00) umstellen
update matchdays set deadline = ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin'
 where status = 'planned' and not waivers_done
   and deadline = starts_on::timestamp at time zone 'Europe/Berlin'
   and ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin' > now();

-- Platz eines Fahrers in der Saisonwertung eines Jahres (Summe der UCI-Punkte aus den Rennergebnissen)
create index if not exists race_events_date on race_events (event_date);
-- Saisonwertung je Jahr fest gespeichert (Rang und Punkte je Fahrer), damit das Fahrerfenster sie sofort zeigt.
-- Wird nach jedem Ergebnisabruf für das laufende und das vorige Jahr neu berechnet.
create table if not exists rider_season_stats (
  rider_slug  text not null references riders (pcs_slug) on delete cascade,
  year        int  not null,
  season_rank int  not null,
  points      numeric not null,
  riders      int  not null,       -- Fahrer mit Punkten in dieser Wertung und Saison
  primary key (rider_slug, year)
);

create or replace function refresh_season_stats(p_year int) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from rider_season_stats where year = p_year;
  insert into rider_season_stats (rider_slug, year, season_rank, points, riders)
  with s as (
    select er.rider_slug, x.gender, sum(er.uci_points) pts
      from event_results er
      join race_events e on e.id = er.event_id
      join riders x on x.pcs_slug = er.rider_slug
     where e.event_date >= make_date(p_year, 1, 1) and e.event_date <= make_date(p_year, 12, 31)
       and er.uci_points > 0
     group by 1, 2)
  select rider_slug, p_year, (rank() over (partition by gender order by pts desc))::int, pts,
         (count(*) over (partition by gender))::int
    from s;
  get diagnostics n = row_count;
  return n;
end $$;

-- Jahre, für die Ergebnisse gespeichert sind (Auswahl „Sortiert nach Punkten …“)
create or replace function result_years() returns setof int
language sql stable security definer set search_path = public as $$
  select distinct extract(year from result_date)::int from results order by 1 desc;
$$;

create or replace function rider_season_rank(p_slug text, p_year int)
returns table (season_rank int, points numeric, riders int)
language sql stable security definer set search_path = public as $$
  select season_rank, points, riders from rider_season_stats where rider_slug = p_slug and year = p_year;
$$;

-- Herkunft der Punkte (einzelne Rennergebnisse)
create or replace function league_point_details(p_league uuid, p_matchday uuid default null)
returns table (matchday_id uuid, manager_id uuid, rider_slug text, race_slug text, race_name text,
               label text, result_date date, points numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_member(p_league) then raise exception 'Keine Berechtigung.'; end if;
  return query
  select s.matchday_id, s.manager_id, s.rider_slug, s.race_slug, rc.name, s.label, s.result_date, s.points
    from _score_rows(p_league) s left join races rc on rc.pcs_slug = s.race_slug
   where p_matchday is null or s.matchday_id = p_matchday
   order by s.result_date desc, s.points desc;
end $$;
