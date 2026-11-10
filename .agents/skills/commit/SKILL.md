---
name: commit
description: Commits in diesem Repo vorbereiten und auf Nutzerauftrag erstellen; Branch, Commit-Titel sowie minimale Tests und Doku festlegen.
---

# Commit-Regeln

## Wohin?

- Auf einem passenden Arbeitszweig committen, nie direkt auf `main` (außer ausdrücklich beauftragt). Einen vorhandenen passenden Zweig weiterverwenden; sonst `<typ>/<kurzes-thema>` anlegen, z. B. `fix/waiver-frist`.
- Integration nach `main` per Pull Request und Squash-Merge. Commit-Aufträge erlauben nicht automatisch Push, PR-Erstellung oder Merge.

## Commit-Name

Format: `<bereich>(<feature>): <typ>: <konkrete Änderung>`

- Bereich: `sql`, `frontend`, `datasync`, `infra` oder `repo`; bei mehreren Bereichen den Schwerpunkt wählen.
- Feature: kurzer fachlicher Name, z. B. `waiver`, `draft`, `schema-build` oder `commit-skill`.
- Typ: `feat`, `fix`, `refactor`, `docs`, `test` oder `chore`.
- Änderung: knapp auf Deutsch, konkret und im Präsens; keine Titel wie „Updates“.
- Beispiel: `sql(waiver): fix: Gebote nach Fristablauf ablehnen`.
- Pro Commit eine zusammenhängende Änderung; nur zugehörige Dateien gezielt stagen und den gestagten Diff prüfen. Keine Secrets oder `web/config.js` einchecken.

## Minimale Tests und Doku

- Neue Tests nur für neue/geänderte Logik oder einen Bugfix: den betroffenen Fall und relevante Grenzfälle absichern, vorhandene Tests bevorzugt erweitern. Reine Doku-, Format- und Skill-Änderungen brauchen keine neuen Tests.
- Betroffene vorhandene Tests und Syntaxprüfungen ausführen; Umfang nach `CLAUDE.md`. SQL: Schema neu bauen, Build-Tests und `--check` ausführen sowie das Schema lokal einspielen; erzeugte `supabase/schema.sql` mit aufnehmen. Frontend: betroffenen Ablauf in mobiler Ansicht prüfen.
- Doku nur bei geänderten Regeln, Bedienung, Einrichtung oder Abläufen anpassen: passende README; bei Spielregeln, Datenabruf oder Liga-Einstellungen außerdem `web/views/rules.js` gemäß `CLAUDE.md`. Die dort genannte Ausnahme für den Draft-Report beachten.
- Ausgeführte Checks und nicht mögliche Prüfungen mit Grund im Abschluss oder PR nennen; ungeprüfte Änderungen nicht als geprüft darstellen.
