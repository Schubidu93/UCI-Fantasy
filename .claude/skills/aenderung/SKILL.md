---
name: aenderung
description: Ablauf für jede Änderung an Runner Fantasy oder UCI Fantasy (Code, Datenbank, Regeln, Tests, Workflows) – von der Prüfung des Wunsches bis zum Merge und der Rückmeldung an den Nutzer. Immer verwenden, bevor etwas geändert wird.
---

# Änderung an Runner Fantasy / UCI Fantasy

Diese Anleitung ist in beiden Apps wortgleich. Die Regeln selbst stehen in `CLAUDE.md`; hier steht die Reihenfolge.
Antworten an den Nutzer: Deutsch, kurz, ohne Fachjargon.

## 1. Wunsch prüfen
- Ist der Wunsch sinnvoll, widerspruchsfrei und gut für die App? Wenn nicht: offen sagen, begründen, bessere Lösung vorschlagen – nicht umsetzen.
- Passt er auch für die andere App? Wenn ja: gleich in beiden umsetzen oder dem Nutzer kurz vorschlagen.

## 2. Vorbereiten
- Beide Apps liegen nebeneinander (`fantasyathletics/`, `uci-fantasy/`); fehlt eine, über `add_repo` holen.
- In beiden auf dem Arbeitszweig der Sitzung, vorher `git fetch origin main`. Ist der letzte Pull Request gemergt,
  den Zweig neu von `origin/main` anlegen – vorher prüfen, dass kein ungemergter Commit verloren geht.

## 3. Umsetzen – wo gehört was hin?
- Gemeinsam (in beiden Apps wortgleich, Liste in `scripts/shared.mjs`): `web/app.js`, `web/lib.js`, `web/style.css`, `web/views/**`,
  `web/vendor/`, gemeinsame Python-Skripte, Testwerkzeuge. Nach jeder Änderung in die andere App kopieren und in beiden
  `node scripts/shared.mjs update`.
- Sportart-spezifisch: `web/sport/**` (Begriffe über `SPORT`, nie „Athlet“/„Fahrer“ fest in gemeinsame Dateien schreiben),
  Datenabruf (`importer/` bzw. `datasync/`).
- Datenbank: nur `supabase/schema/NN_*.sql`, idempotent, gleiche Dateinummern in beiden Apps. Spielregeln in der Datenbank erzwingen.
- Spielregeln, Wertung, Draft, Waiver, Tausch, Spieltage, Datenabruf oder Liga-Einstellungen geändert → Regeln-Seite (`web/sport/rules.js`) mitziehen.
- Jede Regel an genau einer Stelle; keine doppelte Logik; nichts rechts abgeschnitten (iPhone).

## 4. Absichern
- Neues Verhalten bekommt einen Test: Spiellogik in `tests/sql/NN_*.sql` (in beiden Apps gleich), sonst `tests/*.test.ts`
  bzw. `tests/datasync/test_*.py`. Gefundene Fehler zuerst mit einem scheiternden Test belegen.
- In beiden Apps: `npm run lint` und `npm test` (Spiellogik, Skripte, Oberflächentest). Alles muss grün sein.
- Reine Umbauten: Seitentexte vorher/nachher vergleichen (Oberfläche darf sich nicht ändern).
- Eigenen Diff kritisch lesen: Was würde die CI ablehnen? Was bricht in der anderen App?

## 5. Abschließen
- Commit-Regeln (Squash-Merge: der Titel des Pull Requests wird zum Eintrag in `main`, also dort genauso):
  - Erste Zeile `Bereich: was sich ändert` auf Deutsch, höchstens 72 Zeichen, ohne Punkt am Ende –
    Bereiche: `App`, `Datenbank`, `Datenabruf`, `Regeln`, `Tests`, `Abläufe` (Workflows), `Doku`, `Angleichen` (beide Apps).
    Beispiel: `Waiver: Push bei abgelehntem Antrag`.
  - Darunter nach einer Leerzeile kurz das Warum und was Spieler merken; Hinweise wie „App neu laden“ oder „Datenbank wird umgebaut“.
  - Ein Thema je Commit bzw. Pull Request; Änderungen, die beide Apps betreffen, in beiden mit demselben Titel.
  - Keine Geheimnisse, keine persönlichen Daten, keine Modellnamen in Commits.
- Push, Pull Request auf `main` (je App einer), CI abwarten, bei Rot Ursache beheben (nie Tests abschalten).
- Grün → Squash-Merge, Zweig auf `origin/main` zurücksetzen. Bei SQL-Änderungen prüfen, dass „Datenbank einrichten“ grün ist;
  Live-Daten bei Bedarf mit „Datenbank abfragen (nur lesen)“ kontrollieren.
- `CLAUDE.md`/`README.md` aktualisieren, wenn sich Aufbau oder Abläufe ändern.
- Plan des Nutzers („Runner Fantasy – mein Plan“, siehe `CLAUDE.md`) aktualisieren: Erledigtes abhaken bzw. verschieben, Neues eintragen, kurz halten.
- Nutzer kurz informieren: was sich ändert, ob er die App neu laden muss (installierte App ganz schließen und neu öffnen),
  was er selbst tun muss. Keine Dankes- oder Höflichkeitskommentare auf GitHub.
