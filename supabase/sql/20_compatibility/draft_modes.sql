-- Snake-Draft nachrüsten (bestehende Datenbanken)
do $$
begin
  alter table leagues drop constraint if exists leagues_draft_mode_check;
  alter table leagues add constraint leagues_draft_mode_check check (draft_mode in ('live', 'blind', 'snake', 'offline'));
  alter table leagues drop constraint if exists leagues_bid_seconds_check;
  alter table leagues add constraint leagues_bid_seconds_check check (bid_seconds between 5 and 600);
  alter table draft_state drop constraint if exists draft_state_phase_check;
  alter table draft_state add constraint draft_state_phase_check check (phase in ('auction', 'fill', 'snake', 'tiebreak'));
end $$;

