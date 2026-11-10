alter table draft_projection enable row level security;
drop policy if exists draft_projection_read on draft_projection;
create policy draft_projection_read on draft_projection for select using (is_member(league_id));

