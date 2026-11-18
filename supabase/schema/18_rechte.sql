-- =====================================================================
-- Rechte
-- =====================================================================

alter table athletes          enable row level security;
alter table competitions           enable row level security;
alter table athlete_season_stats enable row level security;
alter table results         enable row level security;
alter table sync_status     enable row level security;
alter table leagues         enable row level security;
alter table managers        enable row level security;
alter table draft_state     enable row level security;
alter table draft_lots      enable row level security;
alter table draft_bids      enable row level security;
alter table roster_entries  enable row level security;
alter table matchdays       enable row level security;
alter table lineups         enable row level security;
alter table waiver_claims   enable row level security;
alter table trades          enable row level security;
alter table point_overrides enable row level security;
alter table score_snapshot  enable row level security;
alter table admin_log       enable row level security;
alter table race_events     enable row level security;
alter table event_results   enable row level security;
alter table keepers         enable row level security;
alter table app_config      enable row level security;   -- keine Policies: nur Service-Key
alter table push_subscriptions enable row level security;
alter table notifications   enable row level security;

do $$
declare t text;
begin
  -- öffentliche Stammdaten: lesbar für angemeldete Nutzer
  foreach t in array array['athletes', 'competitions', 'results', 'sync_status', 'race_events', 'event_results', 'athlete_season_stats'] loop
    execute format('drop policy if exists read_all on %I', t);
    execute format('create policy read_all on %I for select to authenticated using (true)', t);
  end loop;
  -- Ligadaten: nur für Mitglieder
  foreach t in array array['managers', 'draft_state', 'draft_lots', 'draft_bids', 'roster_entries',
                           'matchdays', 'trades', 'point_overrides', 'score_snapshot', 'admin_log', 'keepers'] loop
    execute format('drop policy if exists members_read on %I', t);
    execute format('create policy members_read on %I for select to authenticated using (is_member(league_id))', t);
  end loop;
end $$;

drop policy if exists members_read on leagues;
create policy members_read on leagues for select to authenticated using (is_member(id));

drop policy if exists members_read on lineups;
create policy members_read on lineups for select to authenticated
  using (exists (select 1 from matchdays m where m.id = matchday_id and is_member(m.league_id)));

-- Blind-Auktion: verdeckte Gebote sieht nur der Bieter selbst (offengelegt werden sie in draft_bids)
alter table draft_sealed enable row level security;
drop policy if exists own_read on draft_sealed;
create policy own_read on draft_sealed for select to authenticated using (manager_id = my_manager(league_id));

-- Waiver-Anträge: eigene immer, fremde erst nach Abwicklung (Gebote bleiben verdeckt)
drop policy if exists members_read on waiver_claims;
create policy members_read on waiver_claims for select to authenticated
  using (is_member(league_id) and (status <> 'pending' or manager_id = my_manager(league_id)));

drop policy if exists own_read on push_subscriptions;
create policy own_read on push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists own_read on notifications;
create policy own_read on notifications for select to authenticated using (user_id = auth.uid());

-- interne Funktionen nicht direkt aufrufbar
do $$
declare f text;
begin
  -- Interne Funktionen (Name beginnt mit _) und Abläufe, die nur der Service-Key bzw. der Zeitplaner aufruft
  for f in
    select p.oid::regprocedure::text from pg_proc p
     where p.pronamespace = 'public'::regnamespace
       and (p.proname like '\_%' or p.proname in (
            'dispatch_workflow', 'scheduler_tick', 'run_maintenance', 'notify_new_points', 'weekly_summary',
            'refresh_season_stats', 'refresh_pool', 'rebuild_results', 'fit_scoring_coefficients', 'apply_records',
            'relink_event_riders', 'results_from_events', 'ranking_mismatch'))
  loop
    execute format('revoke execute on function %s from public', f);
    begin
      execute format('revoke execute on function %s from anon, authenticated', f);
    exception when undefined_object then null;  -- Rollen gibt es nur in Supabase
    end;
  end loop;
end $$;

-- Live-Updates im Draft-Raum
do $$
begin
  alter publication supabase_realtime add table draft_state;
exception when duplicate_object or undefined_object then null;
end $$;
