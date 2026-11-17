# UCI Fantasy – Hinweise für Claude

Überblick über Aufbau, Hosting, Abläufe und Secrets: siehe `README.md`.

## Arbeitsregeln

- Sprache der App und der Antworten: Deutsch. Die Nutzer sind keine Entwickler – kurz, verständlich, ohne Fachjargon antworten.
- **Architektur:** stabil, nachhaltig, gut gegliedert, nach aktuellem Stand – nicht nur „läuft“. Jede Regel an genau einer Stelle,
  keine doppelte Logik, Änderungen mit Tests absichern, beide Apps gleich aufgebaut (ausdrücklicher Wunsch des Nutzers).
- **Beide Apps mitdenken:** Bei jeder Änderung prüfen, ob sie auch für Runner Fantasy (github.com/Schubidu93/FantasyAthletics) sinnvoll ist,
  und dem Nutzer dann kurz vorschlagen, sie dort zu übernehmen (ausdrücklicher Wunsch des Nutzers).
- **Regeln mitziehen:** Bei jeder Änderung an Spielregeln, Wertung, Draft, Waiver, Tausch, Spieltagen,
  Datenabruf (Zeiten, Quellen, Umfang) oder Liga-Einstellungen immer auch `web/sport/rules.js`
  (Reiter „Regeln“) aktualisieren. Die Regeln sind dynamisch: Texte hängen von den Liga-Einstellungen ab
  (`scoring_mode`, `transfer_mode`, `waiver_mode`, `draft_mode`).
- Der Draft-Report (Noten, „beste Aufstellung“) ist bewusst **nicht** in den Regeln beschrieben – Überraschung für die Mitspieler.
- Datenbankänderungen nur über `supabase/schema/NN_*.sql` (nach Themen, Einspielen in Dateireihenfolge), und zwar **idempotent** (`create or replace`, `add column if not exists`,
  `drop function if exists` bei geänderter Signatur). Nach dem Merge spielt „Datenbank einrichten“ sie automatisch ein.
- Spielregeln werden in der Datenbank erzwungen (security-definer-Funktionen), nicht in der App.
- `web/config.js` ist nur für lokale Tests und darf nicht eingecheckt werden. Keine Secrets in Code oder Chat.
- Mobile first: Die App wird fast nur auf dem iPhone (installiert als Web-App) genutzt. Nichts darf rechts
  abgeschnitten sein; lieber umbrechen oder kürzen. Fristen mit 0:00 Uhr als Vortag ohne Uhrzeit anzeigen (`fmtUntil` in `web/lib.js`).

## Aufbau der App (in beiden Apps gleich)

- `web/app.js`, `web/views/*.js`, `web/views/admin/*.js`: **in Runner Fantasy und UCI Fantasy wortgleich**. Änderungen dort immer in
  beiden Apps vornehmen (Datei kopieren). Alles, worin sich die Sportarten unterscheiden, steht in `web/sport/`:
  - `sport/index.js`: `SPORT` (Begriffe Athlet/Fahrer in allen Fällen, Spaltennamen wie `fk`/`pk`/`add`/`give`, Texte), `pid()`, `rank()`,
    `selectable()`, `usePeopleFilter()`, `PersonLine`, `labelText()`
  - `sport/views.js` (Navigation, eigene Seiten, Laden der Personen), `sport/settings.js` (Liga-Einstellungen), `sport/lineup.js`
    (Aufstellung), `sport/matchdays.js` (Spieltag-Vorschläge), `sport/admin.js` (Zusatzbereiche im Admin) und die Sportart-Seiten
    (Personenliste, Wettkämpfe/Rennen, Profil, ggf. Kalender/Toplisten).
- Datenbank: `supabase/schema/NN_*.sql` mit gleichen Nummern und Namen in beiden Apps.
- Gemeinsame Dateien sind in `scripts/shared.mjs` aufgezählt, ihre Prüfsummen stehen in `shared-files.json` (in beiden Apps gleich).
  `tests/shared.test.ts` scheitert, wenn eine davon nur in einer App geändert wurde: Änderung in die andere App kopieren und in beiden
  `node scripts/shared.mjs update` ausführen. `web/lib.js` und `web/style.css` sind gemeinsam; Leichtathletik-Helfer stehen in `web/sport/lib.js`, Farben und
  sportartspezifische Gestaltung in `web/sport/style.css`.
  Gemeinsam sind auch `datasync/db.py`, `send_push.py`, `send_feedback.py` (App-Name aus `datasync/app_info.py`), `web/vendor/`,
  `tsconfig.json` und der Testablauf `ci.yml`; ihre Tests stehen in `tests/datasync/test_common.py`.
- Tests: `tests/sql/NN_*.sql` (Spiellogik, in beiden Apps gleich), `tests/*.test.ts`, Oberflächentest `tests/ui/smoke.test.ts`
  (öffnet alle Seiten in der iPhone-Ansicht und scheitert bei jedem Fehler; beide Apps gleich).

## Ablauf einer Änderung

Schritt für Schritt: Skill `aenderung` (`.claude/skills/aenderung/SKILL.md`, in beiden Apps gleich). Beim Start einer Cloud-Sitzung
richtet `.claude/hooks/session-start.sh` Pakete und das Test-PostgreSQL ein.

1. Auf einem Arbeitszweig ändern, lokal prüfen (siehe unten).
2. Pull Request auf `main` erstellen und mergen (Squash). Danach laufen automatisch:
   „App veröffentlichen“ (GitHub Pages, wenige Minuten) und bei Änderungen in `supabase/schema/` „Datenbank einrichten“.
3. Live-Daten prüfen: Workflow „Datenbank abfragen (nur lesen)“ (`db-query.yml`) mit einer SQL-Abfrage starten,
   Ergebnis steht im Job-Log. Für einen Überblick: „Datenstand prüfen“ (`db-status.yml`).
4. Dem Nutzer sagen, dass er die App neu laden soll (installierte App: ganz schließen und neu öffnen).

## Lokal testen

- Syntax: `node --check web/views/<datei>.js`; TypeScript: `npm run lint`.
- Datenabruf: `tests/datasync/test_*.py` (unittest, ohne Netz: DataRide und Wettkampfverzeichnis nachgebildet, `FakeDb` statt `db.py`; auch Push und Feedback),
  laufen in `npm test` mit (`tests/datasync.test.ts`) oder einzeln: `python3 -m unittest discover -s tests/datasync -t tests/datasync`.
  Echte DataRide-Antworten (Saison 2025, Rangliste, Tour de France Etappe 1) in `tests/datasync/fixtures/` (`test_real_data.py`),
  neu holen mit dem Workflow „DataRide-Beispieldaten laden“ (`datasync/probe.py`; DataRide ist aus der Claude-Umgebung gesperrt).
- `npm test`: Spiellogik gegen echtes PostgreSQL 16 und Oberflächentest (Playwright, Chromium) (`tests/`, Schema wird zweimal eingespielt = Wiederholbarkeit): Waiver
  (Rangfolge, FAAB), freie Phase, Tausch mit Push-Nachrichten. Lokal z. B. `initdb` + `pg_ctl` mit Socket in `/tmp/fa-pg`, Port 54329
  (`TEST_DATABASE_URL` überschreibt). Läuft in GitHub Actions („Tests“) bei jedem Push und Pull Request.
  SQL-Tests in `tests/sql/NN_*.sql` (pgTAP-Schreibweise `is`/`ok`/`throws_ok`, kleiner Ersatz in `tests/sql/_tap.sql`, Beispieldaten
  `tests/sql/fixtures.sql`): Kader, Draft, Waiver, Tausch, Wertung/Einfrieren, Fristen, Berechtigungen – in beiden Apps gleich gehalten.
- Datenbank: Schema in eine lokale Postgres-Instanz einspielen (`cat supabase/schema/*.sql | psql -v ON_ERROR_STOP=1`);
  für Supabase-Spezifika (`auth.uid()`, Schema `auth`) braucht es kleine Platzhalter.
- Oberfläche: `npx tsx tests/ui/seed.ts` (Beispieldaten: Fahrer, Rennen mit Ergebnislisten, laufende Liga; gibt die Nutzer-ID von
  „alice“ aus) + `DATABASE_URL=… npx tsx tests/ui/mock-api.ts` (Supabase-Schnittstelle auf lokalem Postgres, RLS aktiv),
  `web/config.js` mit `http://localhost:54321`, `python3 -m http.server -d web`, Playwright in iPhone-Ansicht
  (Sitzung als `sb-localhost-auth-token` in localStorage). Wie in Runner Fantasy.
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

## Push „Neue Punkte“ und heiße freie Fahrer

- `notify_new_points()` (aus `run_maintenance` nach dem Ergebnisabruf): neue Zeilen aus `_score_rows` (zählen für einen Spieltag,
  bei Aufstellung nur Aufgestellte, höchstens 14 Tage alt) → eine Nachricht je Manager; je Manager/Fahrer/Rennen/Wertung einmal
  (`point_pushes`). Beim Einführen wurden alle bisherigen Punkte als gemeldet eingetragen (`schema_changes`).
- Fahrer → „🔥 Heiße freie Fahrer“: `rider_points_recent(p_gender, p_days)`; 🔥 = die 10 freien mit den meisten Punkten der letzten 30 Tage.

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
