"""
Rennkalender und Ergebnislisten (Rang, Zeit, UCI-Punkte) aus UCI DataRide laden.

Künftige Rennen zusätzlich aus dem UCI-Wettkampfverzeichnis (uci_calendar.py, als „vorläufig“).

Für jedes Rennen der Saison (Männer und Frauen Elite, Straße):
  Etappen/Renntage → Wertungen → Ergebnisliste (Top 25 + alle Plätze mit UCI-Punkten)

Abgeschlossene Rennen, die schon vollständig geladen sind, werden übersprungen –
der erste Lauf baut die ganze Saison auf (einige Stunden), danach geht es schnell.

Umgebung:
  GENDERS=men,women   welche Wertungen
  LIMIT=5             nur so viele Rennen je Wertung (zum Testen)
  REFRESH=1           auch schon geladene Rennen neu holen
  SEASON_YEAR=2025    andere Saison laden (Standard: aktuelle)
  CLASSES=CN,CC,CM    nur diese Rennklassen (z. B. Meisterschaften gezielt neu laden)
  DRY_RUN=1           nichts speichern, nur anzeigen
"""
import os
import re
import time
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from dataride import DataRide, ms_date, normalize_name, competition_id
import uci_calendar

DRY_RUN = os.environ.get("DRY_RUN") == "1"
GENDERS = os.environ.get("GENDERS", "men,women").split(",")
LIMIT = int(os.environ.get("LIMIT", "0") or 0)
REFRESH = os.environ.get("REFRESH") == "1"
CLASSES = {c for c in os.environ.get("CLASSES", "").split(",") if c}
CATEGORY_NAME = {"men": "Men Elite", "women": "Women Elite"}
FERTIG_NACH_TAGEN = 21     # nach so vielen Tagen gilt ein Ergebnis als endgültig (ein letzter Abgleich danach)
# Täglich nur Rennen der letzten Tage nachladen; mittwochs alle der letzten 3 Wochen (Korrekturen der UCI)
FENSTER = int(os.environ.get("FENSTER") or (FERTIG_NACH_TAGEN if date.today().weekday() == 2 else 3))


def set_seasons(gender, comps):
    """UCI-Saison je Rennen speichern – die UCI-Saison beginnt im Herbst (z. B. Meisterschaften Ende Oktober
    zählen schon zur nächsten Saison). „Punkte 2026“ in der App heißt: UCI-Saison 2026, wie in der Weltrangliste."""
    import db
    by_season = defaultdict(list)
    for c in comps:
        by_season[c["_season"]].append(c["CompetitionId"])
    for year, ids in by_season.items():
        for i in range(0, len(ids), 150):
            db.update("competitions", {"gender": f"eq.{gender}", "dataride_id": f"in.({','.join(map(str, ids[i:i + 150]))})"},
                      {"season": year})


def remove_unlisted(gender, listed_ids, year):
    """Rennen der Saison entfernen, die DataRide für diese Wertung nicht (mehr) führt und für die nie Ergebnisse
    geladen wurden – z. B. reine U23-/Nachwuchs-Meisterschaften. Sie würden sonst ewig ohne Ergebnis im Kalender stehen."""
    import db
    rows = db.select("competitions", {"select": "id,dataride_id", "gender": f"eq.{gender}", "provisional": "is.false",
                               "dataride_id": "not.is.null", "loaded_at": "is.null",
                               "start_date": f"gte.{year}-01-01", "limit": 5000})
    gone = [r["id"] for r in rows if r["dataride_id"] not in listed_ids]
    for slug in gone:
        db.delete("competitions", {"id": f"eq.{slug}", "loaded_at": "is.null"})
    if gone:
        print(f"  {len(gone)} Rennen ohne Elite-Wertung bei der UCI entfernt")


def replace_provisional(gender, cal, today):
    """Vorläufige Kalendereinträge (von Hand, provisional=true) löschen, sobald DataRide das Rennen liefert:
    gleiche Klasse und Start höchstens 3 Tage auseinander. Abgelaufene Platzhalter ebenfalls entfernen."""
    import db
    prov = db.select("competitions", {"select": "id,category,start_date,end_date", "gender": f"eq.{gender}",
                               "provisional": "is.true", "limit": 500})
    gone = []
    for p in prov:
        start = date.fromisoformat(p["start_date"])
        end = date.fromisoformat(p["end_date"] or p["start_date"])
        if end < today - timedelta(days=7) or any(
                c["category"] == p["category"] and abs((date.fromisoformat(c["start_date"]) - start).days) <= 3
                for c in cal):
            gone.append(p["id"])
    for slug in gone:
        db.delete("competitions", {"id": f"eq.{slug}", "provisional": "is.true"})
    if gone:
        print(f"  {len(gone)} vorläufige Kalendereinträge durch DataRide ersetzt bzw. entfernt")


def save_points(slug, events, rows):
    """UCI-Punkte der geladenen Wertungen in die Fantasy-Wertung (Tabelle results) übernehmen.
    Ergebnisse dieses Rennens, die es im neu geladenen Zeitraum nicht mehr gibt (z. B. aberkannt),
    werden entfernt; eingefrorene Spieltage sind davon nicht betroffen (eigener Schnappschuss)."""
    import db
    ev_by_id = {e["id"]: e for e in events}
    points = {}
    for r in rows:
        ev = ev_by_id[r["event_id"]]
        if not r["athlete_id"] or not r["points"] or float(r["points"]) <= 0 or not ev["event_date"]:
            continue
        parts = [p.strip() for p in (ev["stage_name"], ev["event_name"]) if p and p.strip()]
        label = (" · ".join(dict.fromkeys(parts)) or "Ergebnis")[:200]
        points[(r["athlete_id"], label)] = {"athlete_id": r["athlete_id"], "competition_id": slug, "label": label,
                                            "result_date": ev["event_date"], "rank": r["rank"],
                                            "points": float(r["points"])}
    dates = [e["event_date"] for e in events if e["event_date"]]
    if not dates:
        return
    existing = db.select("results", {"select": "id,athlete_id,label,result_date,points", "competition_id": f"eq.{slug}",
                                     "result_date": f"gte.{min(dates)}", "limit": 5000})
    # Mannschaftswertungen (Mixed-Staffel, Teamzeitfahren) stehen ohne Fahrernamen in der Liste – deren Punkte
    # kommen aus dem Abgleich mit der Weltrangliste (check_ranking.py) und bleiben stehen
    stale = [r["id"] for r in existing if (r["athlete_id"], r["label"]) not in points
             and not re.search(r"Team Time Trial|Mixed Relay|TTT", r["label"], re.I)]
    for i in range(0, len(stale), 200):
        db.delete("results", {"id": f"in.({','.join(map(str, stale[i:i + 200]))})"})
    if points:
        db.upsert("results", list(points.values()), "athlete_id,competition_id,label")
    # Push „Neue Punkte“ verschickt die Datenbank (notify_new_points in run_maintenance) – hier nicht noch einmal


# Vollständige Ergebnislisten (statt Top 25 + Plätze mit Punkten) für die wichtigsten Rennen –
# nur Etappen-, Gesamt- und Tagesergebnis, Nebenwertungen (Punkte, Berg, Nachwuchs, Team) bleiben gekürzt
FULL_CLASSES = {"1.UWT", "2.UWT", "1.WWT", "2.WWT", "1.Pro", "2.Pro", "CM"}


def full_list(comp, ev):
    return comp.get("ClassCode") in FULL_CLASSES and not re.search(
        r"Points|Mountain|Young|Youth|Team|Sprint|Combativ", ev.get("EventName") or "", re.I)


def rank_int(text):
    return int(text) if text and str(text).strip().isdigit() else None


def result_row(event_id, r, name_to_slug):
    """Eine Zeile der DataRide-Ergebnisliste → Zeile in event_results (None ohne Namen, z. B. Mannschaftswertungen)."""
    name = (r.get("DisplayName") or r.get("IndividualDisplayName") or "").strip()
    if not name:
        return None
    return {
        "event_id": event_id, "sort_order": r.get("SortOrder") or 0,
        "rank": r.get("RankNumber") or rank_int(r.get("Rank")),
        "rank_text": (r.get("Irm") or r.get("Rank") or "").strip() or None,
        "athlete_name": name, "athlete_id": name_to_slug.get(normalize_name(name)),
        "team": (r.get("TeamName") or "").strip() or None,
        "nation": (r.get("NationName") or "").strip() or None,
        "result": (r.get("ResultValue") or "").strip() or None,
        "points": r.get("PointPcR"),
    }


def stage_order(race):
    """Sortierschlüssel: Prolog 0, Etappe n, Schlusswertungen ans Ende."""
    name = (race.get("RaceName") or "").lower()
    m = re.search(r"stage\s*(\d+)", name)
    if m:
        return int(m.group(1))
    if "prolog" in name:
        return 0
    return 999


FIRST_YEAR = 2025          # ältere Ergebnisse werden nicht gespeichert (Speicherplatz)


def main():
    if os.environ.get("SEASON_YEAR") and int(os.environ["SEASON_YEAR"]) < FIRST_YEAR:
        raise SystemExit(f"Ergebnisse vor {FIRST_YEAR} werden bewusst nicht geladen.")
    dr = DataRide()
    season = dr.season(int(os.environ["SEASON_YEAR"])) if os.environ.get("SEASON_YEAR") else dr.season()
    today = date.today()
    started = time.time()
    print(f"Saison {season['Name']} (ID {season['Id']})")

    if not DRY_RUN:
        import db
    # Künftige Rennen aus dem UCI-Wettkampfverzeichnis (Monate früher als in DataRide)
    try:
        future = uci_calendar.fetch(today)
        print(f"UCI-Wettkampfverzeichnis: {len(future)} künftige Straßenrennen")
    except Exception as e:
        future = None
        print(f"UCI-Wettkampfverzeichnis nicht erreichbar ({e}) – vorläufige Termine bleiben unverändert")
    for gender in GENDERS:
        # Fahrernamen → unsere Fahrer-IDs (für Klick auf Fahrer in der App)
        name_to_slug = {}
        if not DRY_RUN:
            offset = 0
            while True:
                rows = db.select("athletes", {"select": "id,name", "gender": f"eq.{gender}",
                                            "order": "id", "limit": 1000, "offset": offset})
                for r in rows:
                    name_to_slug.setdefault(normalize_name(r["name"]), r["id"])
                offset += len(rows)
                if len(rows) < 1000:
                    break
            loaded = {r["dataride_id"]: r for r in db.select("competitions", {
                "select": "id,dataride_id,end_date,loaded_at", "gender": f"eq.{gender}",
                "dataride_id": "not.is.null", "limit": 5000})}
        else:
            loaded = {}

        comps = dr.competitions(gender, season["Id"])
        for c in comps:
            c["_season"] = season["Year"]
        # Kalender: kommende Rennen dieser und der nächsten Saison (ohne Ergebnisse) speichern
        upcoming = [c for c in comps if (ms_date(c.get("EndDate")) or today) > today]
        nxt = dr.season(season["Year"] + 1)
        if nxt["Id"] != season["Id"]:
            nxt_comps = dr.competitions(gender, nxt["Id"])
            for c in nxt_comps:
                c["_season"] = nxt["Year"]
            upcoming += nxt_comps
            comps += nxt_comps   # die UCI-Saison beginnt im Herbst – schon gefahrene Rennen gleich mitladen
        cal = []
        for c in upcoming:
            start, end = ms_date(c.get("StartDate")), ms_date(c.get("EndDate"))
            if not start:
                continue
            cal.append({"id": competition_id(c["CompetitionName"], start.year, gender), "name": c["CompetitionName"].strip(),
                        "gender": gender, "category": c.get("ClassCode"), "country": c.get("CountryIsoCode3"),
                        "dataride_id": c["CompetitionId"], "start_date": start.isoformat(),
                        "end_date": end.isoformat() if end else None, "season": c["_season"]})
        cal = list({r["id"]: r for r in cal}.values())
        print(f"\n{gender}: {len(cal)} kommende Rennen im Kalender")
        if cal and not DRY_RUN:
            db.upsert("competitions", cal, "id")
        if not DRY_RUN and not LIMIT and not CLASSES:
            if future is not None:
                uci_calendar.sync(gender, cal, today, future)
            else:
                replace_provisional(gender, cal, today)
        if not DRY_RUN:
            set_seasons(gender, comps)
        if not DRY_RUN and not LIMIT and not CLASSES:
            remove_unlisted(gender, {c["CompetitionId"] for c in comps}, season["Year"])
        # bereits gestartete Rennen – laufende Rundfahrten mit den Etappen, die schon gefahren sind
        comps = [c for c in comps if (ms_date(c.get("StartDate")) or today) <= today
                 and (ms_date(c.get("EndDate")) or today).year >= FIRST_YEAR]
        print(f"{gender}: {len(comps)} gestartete Rennen")
        todo, final_pass = [], set()
        for c in comps:
            end = ms_date(c.get("EndDate"))
            prev = loaded.get(c["CompetitionId"])
            age = (today - end).days if end else 0           # < 0: Rennen läuft noch
            never = not (prev and prev.get("loaded_at"))
            recent = age <= FENSTER                          # läuft oder gerade erst beendet
            final = age > FERTIG_NACH_TAGEN and not never \
                and prev["loaded_at"] <= (end + timedelta(days=FERTIG_NACH_TAGEN)).isoformat()
            if REFRESH or never or recent or final:
                todo.append(c)
                if REFRESH or never or final:
                    final_pass.add(c["CompetitionId"])       # komplett laden, nicht nur die letzten Etappen
        if CLASSES:
            todo = [c for c in todo if c.get("ClassCode") in CLASSES]
        if LIMIT:
            todo = todo[:LIMIT]
        print(f"  davon zu laden: {len(todo)} (Fenster {FENSTER} Tage)")

        for n, c in enumerate(todo, 1):
            start, end = ms_date(c.get("StartDate")), ms_date(c.get("EndDate"))
            slug = competition_id(c["CompetitionName"], (start or today).year, gender)
            race_row = {"id": slug, "name": c["CompetitionName"].strip(), "gender": gender,
                        "category": c.get("ClassCode"), "country": c.get("CountryIsoCode3"),
                        "dataride_id": c["CompetitionId"], "season": c["_season"],
                        "start_date": start.isoformat() if start else None, "end_date": end.isoformat() if end else None}
            events, results = [], []
            # Rundfahrten: ältere, schon gespeicherte Etappen nicht jedes Mal neu abfragen
            full = DRY_RUN or c["CompetitionId"] in final_pass
            have = set() if full else {e["stage_name"] for e in db.select(
                "race_events", {"select": "stage_name", "competition_id": f"eq.{slug}", "limit": 2000})}
            cutoff = today - timedelta(days=FENSTER)
            skipped = 0
            try:
                for race in dr.races(c["CompetitionId"]):
                    # Meisterschaften enthalten alle Kategorien (Elite, U23, Junioren, Frauen) – nur die passende
                    cat = (race.get("CategoryCode") or "").strip()
                    if cat and cat != CATEGORY_NAME[gender]:
                        continue
                    day = ms_date(race.get("StartDate"))
                    if not full and day and day < cutoff and race.get("RaceName") in have:
                        skipped += 1
                        continue
                    for ev in dr.events(race["Id"]):
                        events.append({"id": ev["EventId"], "competition_id": slug, "stage_name": race.get("RaceName"),
                                       "stage_no": stage_order(race), "event_name": ev.get("EventName") or "",
                                       "event_date": day.isoformat() if day else None,
                                       "winner": ev.get("WinnerName") or ev.get("IndividualWinner")})
                        for r in dr.results(ev["EventId"], keep_top=None if full_list(c, ev) else 25):
                            row = result_row(ev["EventId"], r, name_to_slug)
                            if row:
                                results.append(row)
            except Exception as e:
                print(f"  ! {c['CompetitionName']}: {e}")
                continue

            label = f"  [{n}/{len(todo)}] {c['CompetitionName'][:40]:<40} {c.get('ClassCode') or '':<6} {len(events):>3} Wertungen {len(results):>5} Zeilen" + (f" ({skipped} ältere Etappen übersprungen)" if skipped else "")
            print(label)
            if DRY_RUN:
                for row in results[:3]:
                    print(f"      {row['rank_text']:>4} {row['athlete_name']:<26} {row['team'] or '':<28} {row['result'] or '':>10} {row['points']}")
                continue
            db.upsert("competitions", [race_row], "id")
            # alte Wertungen dieses Rennens entfernen (auch fälschlich zugeordnete anderer Kategorien) –
            # bei nur teilweise geladenen Rundfahrten bleiben die übersprungenen Etappen stehen
            if not skipped:
                db.delete("race_events", {"competition_id": f"eq.{slug}"})
            if events:
                db.upsert("race_events", events, "id")
                ids = ",".join(str(e["id"]) for e in events)
                db.delete("event_results", {"event_id": f"in.({ids})"})
                # gleiche Sortierposition zweimal (sollte nicht vorkommen) → letzte gewinnt
                uniq = list({(r["event_id"], r["sort_order"]): r for r in results}.values())
                db.upsert("event_results", uniq, "event_id,sort_order")
                save_points(slug, events, uniq)
            db.update("competitions", {"id": f"eq.{slug}"}, {"loaded_at": datetime.now(timezone.utc).isoformat()})

    errors = []
    if not DRY_RUN:
        # Nacharbeiten: jeder Schritt für sich, damit ein Fehler die übrigen (und den Zeitstempel) nicht verhindert
        def step(name, fn):
            try:
                return fn()
            except Exception as e:
                print(f"::warning::{name} fehlgeschlagen: {e}")
                errors.append(name)
        n = step("Fahrer verknüpfen", lambda: db.rpc("relink_event_riders"))
        print(f"{n} Ergebniszeilen neu mit Fahrern verknüpft.")
        n = step("Punkte nachtragen", lambda: db.rpc("results_from_events"))
        print(f"{n} fehlende Punkte-Ergebnisse nachgetragen.")
        for y in sorted({today.year, today.year - 1, season["Year"]}):
            if y >= FIRST_YEAR:
                step(f"Saisonwertung {y}", lambda y=y: db.rpc("refresh_season_stats", {"p_year": y}))
        step("Wartung", lambda: db.rpc("run_maintenance"))     # Stichtage, Spieltage abschließen, Stand aktualisieren
        db.update("sync_status", {"id": "eq.1"}, {"last_run": datetime.now(timezone.utc).isoformat(), "ok": not errors,
                                                  "message": ("Fehler: " + ", ".join(errors)) if errors else None})
    print(f"\nFertig nach {int(time.time() - started) // 60} Minuten.")
    if errors:
        raise SystemExit(f"Nacharbeiten mit Fehlern: {', '.join(errors)}")


if __name__ == "__main__":
    main()
