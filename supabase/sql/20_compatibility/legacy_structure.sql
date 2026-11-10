-- ---------------------------------------------------------------------
-- Umstieg vom ersten Entwurf (Tabelle league_members): Die alten
-- Ligatabellen werden ersetzt – aber nur, solange noch keine Liga existiert.
-- profiles, riders, races und results bleiben erhalten.
-- ---------------------------------------------------------------------
do $$
begin
  if to_regclass('public.league_members') is not null then
    if exists (select 1 from public.leagues) then
      raise exception 'Alte Struktur enthält schon Ligen – bitte melden, dann wird migriert statt ersetzt.';
    end if;
    drop view if exists public.standings, public.matchday_scores, public.matchday_rider_points cascade;
    drop table if exists public.point_corrections, public.trades, public.waiver_claims, public.draft_bids,
                         public.draft_lots, public.lineups, public.roster_entries, public.matchdays,
                         public.league_members, public.leagues cascade;
    drop function if exists public.is_member(uuid) cascade;
    drop function if exists public.is_admin(uuid) cascade;
  end if;
  -- alte Spaltennamen der Stammdaten angleichen
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'riders' and column_name = 'prev_year_rank') then
    alter table public.riders rename column prev_year_rank to uci_rank;
  end if;
end $$;

