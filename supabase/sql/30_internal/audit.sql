create or replace function _log(p_league uuid, p_action text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into admin_log (league_id, user_id, action, details) values (p_league, auth.uid(), p_action, p_details);
$$;

