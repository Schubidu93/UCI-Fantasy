# UCI Fantasy

Fantasy-Radsport mit echten UCI-Punkten: Draft (Live-Auktion, Snake oder offline), Waiver und
freie Transferphase, Tausch, frei setzbare Spieltage, Aufstellung und Liga-Tabelle.
Gewertet werden genau die UCI-Punkte aus den Rennergebnissen (z. B. Platz 7 einer Etappe) –
direkt mit dem Ergebnis, ohne auf die Weltrangliste zu warten.
Datenquelle ist **UCI DataRide** (dataride.uci.ch), die offizielle Datenquelle der UCI.

**App:** https://schubidu93.github.io/UCI-Fantasy/ (installierbar als Web-App auf dem Handy)

## Wo läuft was?

| Teil | Ort |
|---|---|
| App (statische Web-App, Preact) | **GitHub Pages** – veröffentlicht von *App veröffentlichen* |
| Datenbank, Login, Spiellogik, Zeitplaner | **Supabase** (Postgres, Auth, Realtime, pg_cron) |
| Datenabruf und Push-Nachrichten | **GitHub Actions** – gestartet vom Zeitplaner in der Datenbank |

## Aufbau

| Ordner | Inhalt |
|---|---|
| `web/` | Die App: `app.js` (Rahmen, Navigation), `lib.js` (Helfer), `views/` (Bereiche), `sw.js` (Push) |
| `supabase/sql/` | SQL-Quellen nach Aufgabe und Fachbereich: Tabellen, Nachrüstungen, interne Funktionen, App-API, Hintergrundaufgaben, Rechte und Datenkorrekturen |
| `supabase/schema.modules.json` | Verbindliche Ausführungsreihenfolge der SQL-Module |
| `supabase/schema.sql` | Automatisch erzeugtes Gesamtskript für Supabase und den Workflow; nicht direkt bearbeiten |
| `supabase/tests/` | Fachliche pgTAP-Tests und lokale Supabase-Platzhalter; Ausführung über `supabase/test-db.mjs` |
| `datasync/` | Python-Skripte für UCI DataRide (`dataride.py`), Fahrerliste, Rennergebnisse und Push-Versand |
| `.github/workflows/` | Automatische Abläufe (siehe unten) |

Die Spielregeln werden in der Datenbank geprüft (Budget, Uhr, Kadergröße, Fristen,
Waiver-Reihenfolge …), nicht in der App – so kann niemand mogeln.

Die SQL-Module werden mit `node supabase/build-schema.mjs` zu `supabase/schema.sql` zusammengesetzt.
Zuordnung der Module und Arbeitsablauf: siehe [Datenbank-Dokumentation](supabase/README.md).

## Automatische Abläufe

Der Zeitplaner läuft in der Datenbank (pg_cron, alle 15 Minuten, `scheduler_tick`): Er arbeitet
fällige Fristen ab und startet die Workflows über die GitHub-API.

| Workflow | Wann | Was |
|---|---|---|
| Fahrerliste importieren | täglich 6 Uhr | alle Fahrer mit UCI-Punkten (Rang, Team, Nation, Geburtsdatum) |
| Rennergebnisse laden (UCI) | täglich 20 Uhr | Kalender (inkl. nächster Saison), Ergebnislisten und Punkte: neue Rennen, laufende Rundfahrten, letzte 3 Tage; mittwochs 3 Wochen (Korrekturen) |
| Benachrichtigungen senden | nach jedem Ergebnisabruf und bei neuen Nachrichten | Web-Push (Waiver, Draft, „Du bist dran“, neue Punkte …) |
| Feedback senden | direkt nach dem Absenden in der App (Mehr → Feedback) | E-Mail mit Text und Bildern an den Betreiber |
| App veröffentlichen | bei Änderungen auf `main` | App auf GitHub Pages |
| Datenbank einrichten | bei Änderungen unter `supabase/` oder am Datenbank-Workflow | SQL-Build und pgTAP-Tests in Pull Requests prüfen; auf `main` nach erfolgreicher Prüfung Schema einspielen |
| Datenstand prüfen / Datenbank abfragen | per Knopfdruck | Diagnose (nur lesend) |

Fristen ohne Workflow (Waiver-Auswertung, Stichtag, Spieltage abschließen und nach 7 Tagen
einfrieren) erledigt die Datenbank selbst.

## Secrets (GitHub → Settings → Secrets and variables → Actions)

| Secret | Wofür |
|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY` | App (der anon-Key darf öffentlich sein) |
| `SUPABASE_SERVICE_KEY` | Datenabruf und Push-Versand |
| `SUPABASE_DB_URL` | Schema einspielen, Diagnose |
| `GH_DISPATCH_TOKEN` | Zeitplaner darf Workflows starten (wird in den Supabase-Vault übernommen) |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD`, `FEEDBACK_TO` | Feedback per E-Mail (z. B. Gmail: `smtp.gmail.com`, 465, App-Passwort); ohne sie bleibt Feedback in der Tabelle `feedback` |

## Einrichtung (einmalig)

1. Secrets anlegen (siehe oben), **GitHub Pages** aktivieren: Settings → Pages → Source: *GitHub Actions*.
2. Auf `main` mergen – *Datenbank einrichten* und *App veröffentlichen* laufen automatisch.
3. **Fahrer laden:** Actions → *Fahrerliste importieren* → *Run workflow*; danach *Rennergebnisse laden*.
4. **Login-Weiterleitung:** Supabase → Authentication → URL Configuration → *Site URL* auf die App-Adresse.
5. **Google-Login (optional):** OAuth-Client (Webanwendung) in der Google Cloud Console mit Weiterleitung
   `https://<projekt>.supabase.co/auth/v1/callback`, Client-ID und Secret in Supabase → Authentication → Providers → Google.

## Lokal testen

Nach SQL-Änderungen `node supabase/build-schema.mjs` ausführen und die erzeugte Datei mit einchecken.
Mit `node supabase/build-schema.mjs --check` den Stand prüfen;
`node --test supabase/build-schema.test.mjs supabase/test-db.test.mjs` testet Build und Test-Runner ohne Datenbank.
Voraussetzung: Node.js ab Version 22.

`node supabase/test-db.mjs` prüft die Spiellogik mit pgTAP in einer eigenen lokalen PostgreSQL-Testdatenbank.
Unter Windows kann `powershell -NoProfile -ExecutionPolicy Bypass -File supabase/test-db.ps1` den verschlüsselten
lokalen Datenbankzugang verwenden. Voraussetzungen und Umfang: siehe [Datenbanktests](supabase/README.md#fachliche-datenbanktests).

`web/config.example.js` als `web/config.js` kopieren (nicht einchecken), URL und anon-Key eintragen,
dann `python3 -m http.server -d web` und `http://localhost:8000` öffnen.

## Hinweise

- DataRide hat keine dokumentierte API; der Abruf nutzt die Abfragen der Website mit ehrlicher
  Kennung und Pausen zwischen den Abfragen. Künftige Rennen
  kommen zusätzlich aus dem UCI-Wettkampfverzeichnis (uci-competition.tech.uci.ch, öffentliche Schnittstelle der Website,
  `datasync/uci_calendar.py`) und gelten als „vorläufig“, bis DataRide sie führt. Andere Quellen (z. B. ProCyclingStats)
  werden nicht verwendet.
- Fahrer-IDs heißen aus historischen Gründen `pcs_slug` (Format `uci-<DataRide-ID>`).
- Ergebnisse werden ab der Saison 2025 gespeichert.
- Live-Updates im Draft-Raum laufen über Supabase Realtime; fällt das aus, fragt die App alle 1,5 s nach.
- Die Spielregeln stehen in der App unter *Mehr → Regeln* und passen sich den Liga-Einstellungen an.
