-- Einmalig: künftige Spieltage mit dem alten Standard-Stichtag (Start 00:00) auf den neuen (Vortag 20:00) umstellen
update matchdays set deadline = ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin'
 where status = 'planned' and not waivers_done
   and deadline = starts_on::timestamp at time zone 'Europe/Berlin'
   and ((starts_on - 1) + time '20:00')::timestamp at time zone 'Europe/Berlin' > now();

