-- interne Funktionen nicht direkt aufrufbar
do $$
declare f text;
begin
  foreach f in array array[
    '_require_member(uuid)', '_require_admin(uuid)', '_log(uuid,text,jsonb)', '_open_slots(uuid)',
    '_max_bid(uuid)', '_team_limit_ok(uuid,text,text)', '_rider_free(uuid,text,timestamptz)',
    '_release(uuid,uuid,text,date)', '_draft_next(uuid)', '_draft_award(uuid,uuid,int)', '_blind_resolve(uuid)', '_start_draft(uuid)', 'relink_event_riders()',
    'dispatch_workflow(text,jsonb)', 'results_from_events()', 'ranking_mismatch(int)', 'refresh_season_stats(int)', 'weekly_summary()', 'scheduler_tick()', '_notify(uuid,text,text,text)', '_notify_turn(uuid,uuid,uuid,text,timestamptz)', '_check_trade_drops(uuid,text[],text[],int)', '_open_roster_slots(uuid)', '_reset_default_deadlines(uuid,text)', '_snake_pick(uuid,text)', '_score_rows(uuid)',
    '_claim_valid(waiver_claims,leagues)', '_execute_claim(waiver_claims,leagues,matchdays)',
    '_process_waivers(uuid)', '_process_trades(uuid)', '_league_points(uuid)', '_league_table(uuid)',
    '_waiver_order(uuid)', 'run_maintenance()'] loop
    execute format('revoke execute on function %s from public', f);
    begin
      execute format('revoke execute on function %s from anon, authenticated', f);
    exception when undefined_object then null;  -- Rollen gibt es nur in Supabase
    end;
  end loop;
end $$;

