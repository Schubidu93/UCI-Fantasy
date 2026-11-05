# UCI Fantasy – Hinweise für Claude

- Sprache der App und der Antworten: Deutsch.
- **Regeln mitziehen:** Bei jeder Änderung an Spielregeln, Wertung, Draft, Waiver, Tausch, Spieltagen,
  Datenabruf (Zeiten, Quellen, Umfang) oder Liga-Einstellungen immer auch `web/views/rules.js`
  (Reiter „Regeln“) aktualisieren, damit die Beschreibung zum tatsächlichen Verhalten passt.
- Datenbankänderungen nur über `supabase/schema.sql` (idempotent); nach dem Merge spielt der
  Workflow „Datenbank einrichten“ sie automatisch ein.
- `web/config.js` ist nur für lokale Tests und darf nicht eingecheckt werden.
