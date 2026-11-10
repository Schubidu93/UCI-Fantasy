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

