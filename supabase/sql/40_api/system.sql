create or replace function server_now() returns timestamptz
language sql stable as $$ select now(); $$;

