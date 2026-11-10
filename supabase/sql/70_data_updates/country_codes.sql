-- Ländercodes einheitlich wie bei der UCI (IOC): frühere ISO-Codes der vorläufigen Einträge korrigieren
update races set country = case country when 'DEU' then 'GER' when 'NLD' then 'NED' when 'CHE' then 'SUI'
                                        when 'DNK' then 'DEN' when 'ARE' then 'UAE' end
 where country in ('DEU', 'NLD', 'CHE', 'DNK', 'ARE');

