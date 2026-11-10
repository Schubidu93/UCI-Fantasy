# Datenbank-Module

Die SQL-Quellen liegen unter `sql/`, gegliedert nach technischer Aufgabe und fachlichem Bereich.
`schema.sql` wird daraus erzeugt und bleibt das vollständige, wiederholbar ausführbare Skript
für den Supabase SQL-Editor und den Workflow „Datenbank einrichten“.

## Zuordnung

| Pfad | Aufgabe | Beispiele |
|---|---|---|
| `sql/00_*.sql` | Einführung und grundlegende Erweiterungen | pgcrypto, btree_gist |
| `sql/10_tables/` | Tabellen, Indizes und zugehörige idempotente Spaltenergänzungen | Stammdaten, Ligen, Draft, Kader, Spieltage, Transfers, Wertung, Feedback |
| `sql/20_compatibility/` | Historische Strukturwechsel und gezielte Nachrüstungen | erster Schemaentwurf, Draft-Modi, vorläufige Rennen |
| `sql/30_internal/` | Hilfsfunktionen und interne fachliche Verarbeitung | Berechtigungsprüfungen, Kaderplätze, Draft-Zuschläge, Waiver-Auswertung, Punkteberechnung |
| `sql/40_api/` | Von der App aufgerufene Funktionen (RPC) | Liga verwalten, Gebote, Aufstellung, Tabelle, Tauschangebote, Feedback |
| `sql/50_jobs/` | Automatische Verarbeitung und Diagnose | Ergebnisse zuordnen, Saisonstatistiken, Wartung, Wochenbericht, Zeitplaner |
| `sql/60_access/` | Zugriffsregeln und Realtime | Row Level Security, Funktionsrechte, Draft-Publication |
| `sql/70_data_updates/` | Datenkorrekturen und Nachberechnungen beim Einspielen | Ländercodes, alte Fristen, Saisonwerte, Spieltage 2027 |

Die Dateinamen innerhalb einer Kategorie benennen den Fachbereich. Größere Bereiche haben mehrere
Module, etwa `draft_start.sql`, `draft_auction.sql`, `draft_snake.sql` und `draft_offline.sql`.
Die Ordner beschreiben die Aufgabe; welche Funktionen tatsächlich aufgerufen werden dürfen,
bestimmen weiterhin die bestehenden Prüfungen und SQL-Rechte. Die Aufteilung ändert diese Rechte nicht.

## Ausführungsreihenfolge

**Allein `schema.modules.json` bestimmt die Reihenfolge.** Die Nummern der Ordner dienen der Orientierung;
die Dateien werden weder nach Namen sortiert noch kategorieweise ausgeführt.

Die anfängliche Modulliste erhält die Reihenfolge des bisherigen Gesamtskripts vollständig.
Deshalb stehen einzelne Tabellen, Nachrüstungen und Datenkorrekturen auch zwischen Funktionsmodulen.
Beispielsweise wird der Namensindex erst nach `norm_name()` angelegt; Rückbefüllungen laufen erst,
wenn ihre Funktionen definiert sind. Erweiterungen für Namensabgleich und Zeitplaner bleiben ebenfalls
an ihren bisherigen Stellen in den jeweiligen Funktionsmodulen.

Spaltenergänzungen, die bisher direkt an einer Tabellendefinition standen, bleiben bei dieser Tabelle.
Alte Funktionssignaturen werden weiterhin direkt vor der jeweiligen API-Definition entfernt.
So bleibt auch das Verhalten beim erneuten Einspielen in eine vorhandene Datenbank erhalten.

`70_data_updates` ist **kein Migrationsregister**: Auch dort als „einmalig“ kommentierte Blöcke werden
wie bisher bei jedem vollständigen Einspielen ausgeführt und durch ihre bestehenden Bedingungen begrenzt.
Der Build führt kein SQL aus und merkt sich keine bereits ausgeführten Schritte.

## Änderungen vornehmen

Voraussetzung: Node.js ab Version 22; es sind keine zusätzlichen Pakete nötig.

1. Das passende Modul unter `sql/` bearbeiten. Für neue Dateien einen Eintrag an der benötigten Stelle
   in `schema.modules.json` ergänzen. Abhängigkeiten zu Tabellen, Funktionen und Datenkorrekturen beachten.
2. `node supabase/build-schema.mjs` im Repository ausführen.
3. Module, Modulliste und erzeugte `supabase/schema.sql` gemeinsam einchecken.

`schema.sql` nicht direkt bearbeiten. Der Build ergänzt einen Hinweis und für jedes Modul einen
Quellpfad-Kommentar; diese Kommentare erleichtern die Zuordnung in der erzeugten Datei.
SQL-Inhalte werden ansonsten nur mit einheitlichen LF-Zeilenumbrüchen zusammengesetzt.
Module müssen vollständige SQL-Anweisungen enthalten; Funktionskörper und `DO`-Blöcke nicht aufteilen.

## Prüfen und einspielen

```sh
node --test supabase/build-schema.test.mjs supabase/test-db.test.mjs
node supabase/build-schema.mjs --check
psql -v ON_ERROR_STOP=1 -f supabase/schema.sql
```

`--check` verändert keine Datei. Die Prüfung schlägt fehl, wenn `schema.sql` fehlt oder veraltet ist,
ein Modul fehlt, leer oder doppelt eingetragen ist oder eine SQL-Datei unter `sql/` nicht in der
Modulliste steht. Der Build ist unabhängig vom aktuellen Arbeitsverzeichnis.

Der Workflow prüft Build und erzeugtes Schema bereits im Pull Request. Zusätzlich laufen die fachlichen
Tests gegen eine eigene PostgreSQL-17-Instanz. Dazu sind keine produktiven Zugangsdaten nötig.
Auf `main` und bei manuellem Start wird erst nach beiden erfolgreichen Prüfungen das Schema eingespielt.

## Fachliche Datenbanktests

Die Tests unter `tests/database/` verwenden [pgTAP](https://pgtap.org/documentation.html).
Die sieben Suiten prüfen Kader, Draft, Waiver, Tausch, Wertung, Fristen und Berechtigungen.
Neben erfolgreichen Abläufen werden abgelehnte Aktionen, zeitliche Grenzen, Budgetregeln,
Punktkorrekturen und eingefrorene Ergebnisse geprüft. Berechtigungstests wechseln sowohl
die PostgreSQL-Session-Identität als auch die simulierte Nutzer-ID; so greifen RLS und RPC-Prüfungen
auch dann, wenn der Runner als `postgres` verbunden ist.

Voraussetzungen: PostgreSQL ab Version 17 mit `pgcrypto`, `btree_gist` und `unaccent`, `psql` und
Node.js ab Version 22. Der lokale Datenbanknutzer benötigt Superuser-Rechte für das Anlegen der
Testrollen und den Identitätswechsel. Docker wird für lokale Tests nicht benötigt.

```sh
node supabase/test-db.mjs
```

Die Verbindung wird über `PGHOST` (Standard `127.0.0.1`), `PGPORT` (Standard `5432`), `PGUSER`
(Standard `postgres`) sowie `PGPASSWORD` oder die übliche Passwortdatei konfiguriert. Ein abweichender
Pfad zu `psql` kann mit `PSQL` gesetzt werden. Der Runner akzeptiert ausschließlich localhost.
Passwörter gehören nicht ins Repository oder in Kommandozeilenargumente.

Unter Windows kann der vorhandene, mit Windows verschlüsselte lokale Zugang verwendet werden:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File supabase/test-db.ps1
```

Das Hilfsskript liest bei Bedarf `%LOCALAPPDATA%\PostgreSQL\17\postgres.credential.xml` und setzt
das Passwort nur für den Testprozess. Eine bereits gesetzte Verbindung wird über die genannten
Umgebungsvariablen gesteuert. Die Ausführungsrichtlinie wird nicht dauerhaft verändert.

Der Testlauf führt folgende Schritte aus:

1. Eine neue, zufällig benannte Datenbank `uci_fantasy_test_*` anlegen.
2. Lokale Auth-Platzhalter und Supabase-ähnliche Tabellenrechte aus `tests/support/bootstrap.sql` einrichten.
3. Das vollständige `schema.sql` einspielen und pgTAP nur in dieser Datenbank laden.
4. Jede Testsuite mit eigenen Beispieldaten in einer Transaktion ausführen und zurückrollen.
5. Erneutes Einspielen mit Bestandsdaten prüfen; Inhalte von Ligen, Managern, Kadern und Spieltagen vergleichen.
6. Die selbst angelegte Testdatenbank im Erfolgs- und Fehlerfall entfernen.

Für einen reproduzierbaren Lauf lädt der Runner das reine SQL-Framework pgTAP 1.3.4 aus dem offiziellen
Repository, prüft dessen fest hinterlegte SHA-256-Summe und speichert es im temporären Benutzerordner.
Bei unverändertem Cache sind weitere Läufe ohne Download möglich. Die drei Template-Ersetzungen
entsprechen dem upstream Makefile. Es werden weder Serverdateien installiert noch pgTAP-Funktionen
in der produktiven Modulliste ergänzt. Die TAP-Auswertung erkennt auch fehlgeschlagene Assertions,
bei denen `psql` selbst den Exit-Code 0 liefert; übersprungene Tests gelten nicht als Erfolg.

`tests/support/fixtures.sql` enthält gemeinsame, rein lokale Testdaten. Jede neue Suite beginnt mit
`begin`, lädt diese Datei mit `\ir`, setzt einen pgTAP-Testplan und endet mit `finish()` und `rollback`.
Die Tests bleiben außerhalb von `sql/` und `schema.modules.json`.

Die Suite prüft PostgreSQL-Fachlogik und Zugriffsrechte mit lokalen Auth-Platzhaltern. Der tatsächliche
Supabase-Login, Realtime-Verbindungen, Vault, pg_cron, pg_net und externe GitHub-/Push-Abläufe sind
damit nicht abgedeckt. Die beim Einspielen erwarteten Hinweise zu fehlenden Zeitplaner-Erweiterungen
werden abgefangen; SQL-Fehler oder fehlgeschlagene Assertions lassen den Testlauf fehlschlagen.
