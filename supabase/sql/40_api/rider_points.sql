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

