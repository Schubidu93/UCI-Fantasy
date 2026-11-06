# UCI Fantasy – Hinweise für Claude

Überblick über Aufbau, Hosting, Abläufe und Secrets: siehe `README.md`.

## Arbeitsregeln

- Sprache der App und der Antworten: Deutsch. Die Nutzer sind keine Entwickler – kurz, verständlich, ohne Fachjargon antworten.
- **Regeln mitziehen:** Bei jeder Änderung an Spielregeln, Wertung, Draft, Waiver, Tausch, Spieltagen,
  Datenabruf (Zeiten, Quellen, Umfang) oder Liga-Einstellungen immer auch `web/views/rules.js`
  (Reiter „Regeln“) aktualisieren. Die Regeln sind dynamisch: Texte hängen von den Liga-Einstellungen ab
  (`scoring_mode`, `transfer_mode`, `waiver_mode`, `draft_mode`).
- Der Draft-Report (Noten, „beste Aufstellung“) ist bewusst **nicht** in den Regeln beschrieben – Überraschung für die Mitspieler.
- Datenbankänderungen nur über `supabase/schema.sql`, und zwar **idempotent** (`create or replace`, `add column if not exists`,
  `drop function if exists` bei geänderter Signatur). Nach dem Merge spielt „Datenbank einrichten“ sie automatisch ein.
- Spielregeln werden in der Datenbank erzwungen (security-definer-Funktionen), nicht in der App.
- `web/config.js` ist nur für lokale Tests und darf nicht eingecheckt werden. Keine Secrets in Code oder Chat.
- Mobile first: Die App wird fast nur auf dem iPhone (installiert als Web-App) genutzt. Nichts darf rechts
  abgeschnitten sein; lieber umbrechen oder kürzen. Fristen mit 0:00 Uhr als Vortag ohne Uhrzeit anzeigen (`fmtUntil` in `web/lib.js`).

## Ablauf einer Änderung

1. Auf einem Arbeitszweig ändern, lokal prüfen (siehe unten).
2. Pull Request auf `main` erstellen und mergen (Squash). Danach laufen automatisch:
   „App veröffentlichen“ (GitHub Pages, wenige Minuten) und bei `schema.sql`-Änderungen „Datenbank einrichten“.
3. Live-Daten prüfen: Workflow „Datenbank abfragen (nur lesen)“ (`db-query.yml`) mit einer SQL-Abfrage starten,
   Ergebnis steht im Job-Log. Für einen Überblick: „Datenstand prüfen“ (`db-status.yml`).
4. Dem Nutzer sagen, dass er die App neu laden soll (installierte App: ganz schließen und neu öffnen).

## Lokal testen

- Syntax: `node --check web/views/<datei>.js`, `python3 -c "import ast; ast.parse(open('datasync/<datei>.py').read())"`.
- Datenbank: Schema in eine lokale Postgres-Instanz einspielen (`psql -v ON_ERROR_STOP=1 -f supabase/schema.sql`);
  für Supabase-Spezifika (`auth.uid()`, Schema `auth`) braucht es kleine Platzhalter.
- Oberfläche: `web/config.example.js` → `web/config.js`, statisch ausliefern (`python3 -m http.server -d web`) und mit
  Playwright in der iPhone-Ansicht durchklicken. Die PostgREST-API lässt sich durch einen kleinen Mock ersetzen.
- Achtung: Die echte API liefert max. **1000 Zeilen** pro Abfrage – große Abfragen seitenweise (`all()` / `rpcAll()` in `web/lib.js`).
- Achtung: Bei Einbettungen (`leagues(...)`) den Fremdschlüssel nennen, sobald es mehrere Wege gibt
  (z. B. `leagues!managers_league_id_fkey(...)`).

## Daten

- Quelle nur **UCI**: DataRide (`datasync/dataride.py`) und für künftige Termine das UCI-Wettkampfverzeichnis
  (`datasync/uci_calendar.py`, uci-competition.tech.uci.ch). Ehrliche Kennung, Pausen zwischen Abfragen. Keine anderen
  Quellen (kein ProCyclingStats), keine Umgehung von Bot-Schutz.
- `datasync/race_results.py`: Kalender, Ergebnislisten und Punkte (täglich 20 Uhr; WorldTour/ProSeries/WM vollständig).
  Punkte der Wertung stehen in `results`, die Ergebnislisten in `race_events`/`event_results`.
- `datasync/import_riders.py`: Fahrerliste (täglich 6 Uhr). Fahrer-ID heißt historisch `pcs_slug` (`uci-<id>`).
- Daten erst ab Saison 2025. Ländercodes in der App einheitlich IOC (`nationCode` in `web/lib.js`).

## Feedback

- App: Mehr → Feedback (`web/views/feedback.js`), Bilder werden im Browser verkleinert (JPEG, max. 1600 px).
- Datenbank: `submit_feedback` → Tabellen `feedback`/`feedback_images`; startet sofort „Feedback senden“ (`feedback.yml`,
  `datasync/send_feedback.py`, SMTP-Secrets). Bilder werden nach dem Versand gelöscht.

## Offene Punkte (Stand November 2026)

- GitHub-Secret `GH_DISPATCH_TOKEN` muss vom Repo-Besitzer eingetragen werden (Fine-grained Token, nur dieses Repo,
  „Actions: Read and write“, danach „Datenbank einrichten“ einmal starten). Ohne es starten Zeitplaner-Abläufe
  (Ergebnisse 20 Uhr, Fahrerliste 6 Uhr, Push, Wochen-Zusammenfassung) nicht automatisch. Ablauf des Tokens nach ~1 Jahr.
- Künftige Rennen sind vorläufig (`races.provisional`, aus dem Wettkampfverzeichnis; Geschlecht ohne Angabe per Name/Klasse
  geschätzt), werden bei jedem Abruf neu gesetzt und durch DataRide ersetzt (gleiche Klasse, ±3 Tage).
- Ideen für später: Startlisten (UCI liefert keine), Verletzungen/Pausen markieren, mehrere Admins pro Liga.
