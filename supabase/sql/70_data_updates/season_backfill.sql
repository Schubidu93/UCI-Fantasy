-- Saison bisher nicht bekannter Rennen vorläufig schätzen (ab 20. Oktober zählt die nächste UCI-Saison);
-- der nächste Ergebnisabruf setzt den genauen Wert aus DataRide
update races set season = extract(year from start_date)::int
       + case when start_date >= make_date(extract(year from start_date)::int, 10, 20) then 1 else 0 end
 where season is null and start_date is not null;

