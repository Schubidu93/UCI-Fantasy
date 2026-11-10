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

