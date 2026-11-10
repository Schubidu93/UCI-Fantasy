-- Jede Suite lädt diese Daten innerhalb ihrer eigenen, zurückgerollten Transaktion.
create schema test_support;
grant usage on schema test_support to public;
create function test_support.user_id(n int) returns uuid language sql immutable as $$
  select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function test_support.league(n int default 1) returns uuid language sql immutable as $$
  select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function test_support.manager(n int) returns uuid language sql immutable as $$
  select ('20000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function test_support.matchday(n int default 1) returns uuid language sql immutable as $$
  select ('30000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid;
$$;
create function test_support.rider(n int) returns text language sql immutable as $$
  select 'test-rider-' || n;
$$;
create function test_support.login(n int) returns void language plpgsql as $$ begin
  perform set_config('request.jwt.claim.sub', test_support.user_id(n)::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
end $$;

insert into auth.users (id, email)
select test_support.user_id(n), 'user' || n || '@example.invalid' from generate_series(1, 3) n;
insert into riders (pcs_slug, name, gender, team, uci_rank)
select test_support.rider(n), 'Testfahrer ' || n, 'men',
       case when n % 2 = 1 then 'Team A' else 'Team B' end, n
  from generate_series(1, 12) n;
insert into leagues (id, name, admin_user, roster_size, season_start, season_end, status)
values (test_support.league(1), 'Liga A', test_support.user_id(1), 5, current_date - 100, current_date + 365, 'active'),
       (test_support.league(2), 'Liga B', test_support.user_id(3), 5, current_date - 100, current_date + 365, 'active');
insert into managers (id, league_id, user_id, team_name, budget_left, draft_position)
values (test_support.manager(1), test_support.league(1), test_support.user_id(1), 'Manager A', 70, 1),
       (test_support.manager(2), test_support.league(1), test_support.user_id(2), 'Manager B', 80, 2),
       (test_support.manager(3), test_support.league(2), test_support.user_id(3), 'Manager C', 100, 1);
insert into draft_state (league_id) values (test_support.league(1)), (test_support.league(2));
insert into roster_entries (league_id, manager_id, rider_slug, price, source, acquired_on)
values (test_support.league(1), test_support.manager(1), test_support.rider(1), 10, 'draft', current_date - 60),
       (test_support.league(1), test_support.manager(1), test_support.rider(2), 20, 'draft', current_date - 60),
       (test_support.league(1), test_support.manager(2), test_support.rider(3), 15, 'draft', current_date - 60),
       (test_support.league(1), test_support.manager(2), test_support.rider(4), 5, 'draft', current_date - 60),
       (test_support.league(2), test_support.manager(3), test_support.rider(12), 0, 'draft', current_date - 60);
