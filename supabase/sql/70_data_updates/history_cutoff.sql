-- Ergebnisse vor 2025 werden nicht gespeichert (auch keine Rennen der Saison 2025, die schon im Herbst 2024 lagen)
delete from results where result_date < date '2025-01-01';
delete from races where coalesce(end_date, start_date) < date '2025-01-01';

