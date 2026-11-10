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

