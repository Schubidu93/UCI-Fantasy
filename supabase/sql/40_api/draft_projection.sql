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
      select distinct d.manager_id, d.rider_slug from draft_lots d where d.league_id = p_league and d.manager_id is not null),
    mds as (   -- Spieltage ein Jahr früher; ohne Spieltage: die ganze Vorsaison als ein Block
      select m.name, (m.starts_on - interval '1 year')::date s, (m.ends_on - interval '1 year')::date e
        from matchdays m where m.league_id = p_league
      union all
      select 'Vorjahr', make_date(extract(year from l.season_start)::int - 1, 1, 1), make_date(extract(year from l.season_start)::int - 1, 12, 31)
       where not exists (select 1 from matchdays where league_id = p_league)),
    rp as (
      select t.manager_id, md.name, t.rider_slug, sum(r.uci_points) p
        from team t cross join mds md
        join results r on r.rider_slug = t.rider_slug and r.result_date between md.s and md.e
       group by 1, 2, 3),
    best as (
      select rp.manager_id, rp.name, sum(rp.p) p from (
        select rp.*, row_number() over (partition by rp.manager_id, rp.name order by rp.p desc) rn from rp) rp
       where rn <= v_x group by 1, 2)
    select p_league, mg.id, coalesce(sum(b.p), 0), coalesce(jsonb_object_agg(b.name, round(b.p, 1)) filter (where b.name is not null), '{}'), v_sig
      from managers mg left join best b on b.manager_id = mg.id
     where mg.league_id = p_league group by mg.id;
  end if;
  return query select d.manager_id, d.points, d.per_md from draft_projection d where d.league_id = p_league;
end $$;

