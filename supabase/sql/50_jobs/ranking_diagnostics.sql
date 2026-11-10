-- Fahrer, deren Punkte in der Weltrangliste nicht zu unseren Rennpunkten der letzten 52 Wochen passen
-- (z. B. Punkte aus Mannschaftswertungen wie der Mixed-Staffel, die in keiner Einzel-Ergebnisliste stehen)
create or replace function ranking_mismatch(p_limit int default 300)
returns table (rider_slug text, gender text, ranking_points numeric, ours numeric)
language sql stable security definer set search_path = public as $$
  select x.pcs_slug, x.gender, x.ranking_points, coalesce(sum(r.uci_points), 0)
    from riders x
    left join results r on r.rider_slug = x.pcs_slug and r.result_date > current_date - 366
   where x.ranking_points > 0
   group by x.pcs_slug, x.gender, x.ranking_points
  having abs(x.ranking_points - coalesce(sum(r.uci_points), 0)) > 0.5
   order by x.ranking_points desc
   limit p_limit;
$$;

