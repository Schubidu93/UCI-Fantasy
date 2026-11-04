# UCI Fantasy

Fantasy-Radsport mit echten UCI-Punkten: Auktions-Draft mit 100 Budgetpunkten, Waiver,
Tausch, frei setzbare Spieltage und Liga-Tabelle. Punkte = die UCI-Punkte, die ein Fahrer
für jedes Ergebnis in der UCI-Weltrangliste erhält, solange er im Kader steht.
Datenquelle ist UCI DataRide (dataride.uci.ch), die offizielle Seite des UCI-Rankings.

## Aufbau

| Ordner | Inhalt |
|---|---|
| `web/` | Die App (läuft im Browser, wird über GitHub Pages veröffentlicht) |
| `supabase/schema.sql` | Datenbank: Tabellen, Zugriffsrechte und die komplette Spiellogik (Auktion, Waiver, Tausch, Wertung) |
| `pcs_sync/` | Python-Skripte, die Fahrer und Ergebnisse von UCI DataRide holen (`dataride.py`) |
| `.github/workflows/` | Automatische Abläufe (siehe unten) |

Die Spielregeln werden in der Datenbank geprüft (Budget, 15-Sekunden-Uhr, Kadergröße,
Waiver-Reihenfolge …), nicht in der App – so kann niemand mogeln, auch nicht mit einem
manipulierten Browser.

## Automatische Abläufe

| Workflow | Wann | Was |
|---|---|---|
| Ergebnisse abrufen (UCI) | täglich 05:00 UTC | Ergebnisse aller Kaderfahrer holen, aberkannte entfernen, Stichtage abrechnen, Spieltage abschließen und 7 Tage danach einfrieren |
| Fahrerliste importieren | mittwochs + per Knopfdruck | UCI-Weltrangliste Männer/Frauen (je 1000 Fahrer); neue Fahrer sind automatisch frei |
| App veröffentlichen | bei Änderungen in `web/` auf `main` | App auf GitHub Pages stellen |
| Datenbank einrichten | nur per Knopfdruck | `supabase/schema.sql` einspielen (optional, braucht `SUPABASE_DB_URL`) |

## Einrichtung (einmalig)

1. **Datenbank:** Inhalt von `supabase/schema.sql` im Supabase SQL-Editor einfügen und *Run*.
   Das Skript ersetzt die Ligatabellen des ersten Entwurfs (nur solange noch keine Liga existiert),
   behält `profiles`, `riders`, `races`, `results` und kann gefahrlos erneut ausgeführt werden.
2. **Secret `SUPABASE_ANON_KEY`** in GitHub anlegen (Repository → Settings → Secrets and variables → Actions).
   Wert: Supabase → Project Settings → API → *anon public*. Dieser Schlüssel darf öffentlich sein;
   `SUPABASE_URL` und `SUPABASE_SERVICE_KEY` sind schon vorhanden.
3. **GitHub Pages aktivieren:** Settings → Pages → Source: *GitHub Actions*.
4. **Fahrer laden:** Actions → *Fahrerliste importieren* → *Run workflow*.
5. **Auf `main` bringen** (Pull Request mergen) – dann veröffentlicht *App veröffentlichen* die App
   unter `https://<benutzer>.github.io/<repo>/`.
6. **Login-Weiterleitung:** Supabase → Authentication → URL Configuration → *Site URL* auf diese
   Adresse setzen (sonst führen Bestätigungs- und Magic-Links ins Leere).
7. **Google-Login (optional):** In der Google Cloud Console einen OAuth-Client (Typ *Webanwendung*)
   anlegen, als *Autorisierte Weiterleitungs-URI* `https://<projekt>.supabase.co/auth/v1/callback`
   eintragen, dann Client-ID und Secret in Supabase → Authentication → Sign In / Providers → Google
   eintragen und aktivieren.

## Lokal testen

`web/config.example.js` als `web/config.js` kopieren, URL und anon-Key eintragen, dann z. B.
`python3 -m http.server -d web` und `http://localhost:8000` öffnen.

## Hinweise

- Die UCI rechnet ihr Ranking einmal pro Woche neu – neue Punkte erscheinen deshalb mit bis zu
  einer Woche Verzögerung. Spieltage bleiben 7 Tage nach Abschluss für Korrekturen offen.
- Aberkannte Ergebnisse (bei der UCI als ungültig markiert) werden automatisch abgezogen.
- DataRide hat keine dokumentierte API; der Abruf nutzt die Abfragen der Website, mit ehrlicher
  Kennung und Pausen. ProCyclingStats blockiert automatische Abrufe und wird nicht verwendet.
- Live-Updates im Draft-Raum laufen über Supabase Realtime; fällt das aus, fragt die App alle 1,5 s nach.
