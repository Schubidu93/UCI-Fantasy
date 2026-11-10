create or replace function weekly_summary() returns int
language plpgsql security definer set search_path = public as $$
declare lg leagues; n int := 0; k int;
begin
  for lg in select * from leagues where status = 'active' loop
    with week as (
      select s.manager_id, s.rider_slug, sum(s.points) pts
        from _score_rows(lg.id) s where s.result_date > current_date - 7 group by 1, 2),
    per_mgr as (
      select manager_id, sum(pts) total,
             (array_agg(rider_slug order by pts desc))[1] best_rider, max(pts) best_pts
        from week group by 1)
    insert into notifications (user_id, title, body, url)
    select m.user_id,
           '📊 Deine Woche: +' || round(coalesce(p.total, 0))::text || ' Punkte',
           lg.name || ': Platz ' || t."position" || ' von ' || (select count(*) from managers where league_id = lg.id)
             || coalesce(' · bester Fahrer ' || _rname(p.best_rider) || ' (+' || round(p.best_pts)::text || ')', ' · diese Woche keine Punkte'),
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

