-- ---- Vorläufige Kalendereinträge -----------------------------------------------------------
-- Künftige Rennen, die DataRide noch nicht kennt, kommen aus dem UCI-Wettkampfverzeichnis
-- (datasync/uci_calendar.py, täglich) und werden ersetzt, sobald DataRide das Rennen liefert.
alter table races add column if not exists provisional boolean not null default false;
