-- Saisonwertungen beim Einspielen aufbauen (bzw. aktualisieren)
select refresh_season_stats(y) from generate_series(2025, extract(year from current_date)::int) y;

