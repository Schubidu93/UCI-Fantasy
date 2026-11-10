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

