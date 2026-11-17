-- Minimaler Ersatz für pgTAP (plan, is, ok, lives_ok, throws_ok, finish), damit die SQL-Tests ohne
-- Zusatzpaket auf jedem PostgreSQL laufen. Ergebnisse sammelt _tap_results; finish() meldet Fehler als Exception.
create schema if not exists test_support;
grant usage on schema test_support to public;
create temp table if not exists _tap_results (n serial, ok boolean, description text, detail text);
grant all on _tap_results to public;
grant usage, select on sequence _tap_results_n_seq to public;

create or replace function test_support.plan(int) returns void language sql as $$ select $$;

create or replace function test_support._tap(p_ok boolean, p_desc text, p_detail text default null) returns text
language plpgsql security definer as $$
begin
  insert into _tap_results (ok, description, detail) values (coalesce(p_ok, false), p_desc, p_detail);
  return case when coalesce(p_ok, false) then 'ok' else 'not ok' end || ' - ' || p_desc;
end $$;

create or replace function test_support.ok(boolean, text) returns text language sql as $$ select test_support._tap($1, $2) $$;

create or replace function test_support.is(anyelement, anyelement, text) returns text language sql as $$
  select test_support._tap($1 is not distinct from $2, $3,
    case when $1 is distinct from $2 then 'erhalten: ' || coalesce($1::text, 'NULL') || ', erwartet: ' || coalesce($2::text, 'NULL') end)
$$;

create or replace function test_support.lives_ok(p_sql text, p_desc text) returns text language plpgsql as $$
begin
  execute p_sql;
  return test_support._tap(true, p_desc);
exception when others then
  return test_support._tap(false, p_desc, 'Fehler: ' || sqlerrm);
end $$;

create or replace function test_support.throws_ok(p_sql text, p_code text, p_msg text, p_desc text) returns text
language plpgsql as $$
begin
  execute p_sql;
  return test_support._tap(false, p_desc, 'kein Fehler ausgelöst');
exception when others then
  return test_support._tap((p_code is null or sqlstate = p_code) and (p_msg is null or sqlerrm = p_msg), p_desc,
    'Fehler ' || sqlstate || ': ' || sqlerrm);
end $$;

create or replace function test_support.finish() returns setof text language plpgsql as $$
declare v text;
begin
  select string_agg('✗ ' || description || coalesce(' (' || detail || ')', ''), E'\n' order by n) into v
    from _tap_results where not ok;
  if v is not null then raise exception E'Fehlgeschlagene Prüfungen:\n%', v; end if;
  return query select '✓ ' || description from _tap_results order by n;
end $$;
