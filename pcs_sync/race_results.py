"""
Rennkalender und Ergebnislisten (Rang, Zeit, UCI-Punkte) aus UCI DataRide laden.

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
from datetime import date, datetime, timedelta, timezone

from dataride import DataRide, ms_date, normalize_name, race_slug
from sync import notify_points

DRY_RUN = os.environ.get("DRY_RUN") == "1"
GENDERS = os.environ.get("GENDERS", "men,women").split(",")
LIMIT = int(os.environ.get("LIMIT", "0") or 0)
REFRESH = os.environ.get("REFRESH") == "1"
CLASSES = {c for c in os.environ.get("CLASSES", "").split(",") if c}
CATEGORY_NAME = {"men": "Men Elite", "women": "Women Elite"}
FERTIG_NACH_TAGEN = 21     # so lange nach Rennende wird ein Rennen noch aktualisiert (Korrekturen)


def rank_int(text):
    return int(text) if text and str(text).strip().isdigit() else None


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
    for gender in GENDERS:
        # Fahrernamen → unsere Fahrer-IDs (für Klick auf Fahrer in der App)
        name_to_slug = {}
        if not DRY_RUN:
            offset = 0
            while True:
                rows = db.select("riders", {"select": "pcs_slug,name", "gender": f"eq.{gender}",
                                            "order": "pcs_slug", "limit": 1000, "offset": offset})
                for r in rows:
                    name_to_slug.setdefault(normalize_name(r["name"]), r["pcs_slug"])
                offset += len(rows)
                if len(rows) < 1000:
                    break
            loaded = {r["dataride_id"]: r for r in db.select("races", {
                "select": "pcs_slug,dataride_id,end_date,loaded_at", "gender": f"eq.{gender}",
                "dataride_id": "not.is.null", "limit": 5000})}
        else:
            loaded = {}

        comps = dr.competitions(gender, season["Id"])
        # Kalender: kommende Rennen dieser und der nächsten Saison (ohne Ergebnisse) speichern
        upcoming = [c for c in comps if (ms_date(c.get("EndDate")) or today) > today]
        nxt = dr.season(season["Year"] + 1)
        if nxt["Id"] != season["Id"]:
            nxt_comps = dr.competitions(gender, nxt["Id"])
            upcoming += nxt_comps
            comps += nxt_comps   # die UCI-Saison beginnt im Herbst – schon gefahrene Rennen gleich mitladen
        cal = []
        for c in upcoming:
            start, end = ms_date(c.get("StartDate")), ms_date(c.get("EndDate"))
            if not start:
                continue
            cal.append({"pcs_slug": race_slug(c["CompetitionName"], start.year, gender), "name": c["CompetitionName"].strip(),
                        "gender": gender, "uci_class": c.get("ClassCode"), "country": c.get("CountryIsoCode3"),
                        "dataride_id": c["CompetitionId"], "start_date": start.isoformat(),
                        "end_date": end.isoformat() if end else None})
        cal = list({r["pcs_slug"]: r for r in cal}.values())
        print(f"\n{gender}: {len(cal)} kommende Rennen im Kalender")
        if cal and not DRY_RUN:
            db.upsert("races", cal, "pcs_slug")
        # bereits gestartete Rennen – laufende Rundfahrten mit den Etappen, die schon gefahren sind
        comps = [c for c in comps if (ms_date(c.get("StartDate")) or today) <= today]
        print(f"{gender}: {len(comps)} gestartete Rennen")
        todo = []
        for c in comps:
            end = ms_date(c.get("EndDate"))
            prev = loaded.get(c["CompetitionId"])
            done = prev and prev.get("loaded_at") and end and (today - end).days > FERTIG_NACH_TAGEN \
                and prev["loaded_at"] > (end + timedelta(days=FERTIG_NACH_TAGEN)).isoformat()
            if REFRESH or not done:
                todo.append(c)
        if CLASSES:
            todo = [c for c in todo if c.get("ClassCode") in CLASSES]
        if LIMIT:
            todo = todo[:LIMIT]
        print(f"  davon zu laden: {len(todo)}")

        for n, c in enumerate(todo, 1):
            start, end = ms_date(c.get("StartDate")), ms_date(c.get("EndDate"))
            slug = race_slug(c["CompetitionName"], (start or today).year, gender)
            race_row = {"pcs_slug": slug, "name": c["CompetitionName"].strip(), "gender": gender,
                        "uci_class": c.get("ClassCode"), "country": c.get("CountryIsoCode3"),
                        "dataride_id": c["CompetitionId"],
                        "start_date": start.isoformat() if start else None, "end_date": end.isoformat() if end else None}
            events, results = [], []
            try:
                for race in dr.races(c["CompetitionId"]):
                    # Meisterschaften enthalten alle Kategorien (Elite, U23, Junioren, Frauen) – nur die passende
                    cat = (race.get("CategoryCode") or "").strip()
                    if cat and cat != CATEGORY_NAME[gender]:
                        continue
                    day = ms_date(race.get("StartDate"))
                    for ev in dr.events(race["Id"]):
                        events.append({"id": ev["EventId"], "race_slug": slug, "stage_name": race.get("RaceName"),
                                       "stage_no": stage_order(race), "event_name": ev.get("EventName") or "",
                                       "event_date": day.isoformat() if day else None,
                                       "winner": ev.get("WinnerName") or ev.get("IndividualWinner")})
                        for r in dr.results(ev["EventId"]):
                            name = (r.get("DisplayName") or r.get("IndividualDisplayName") or "").strip()
                            if not name:
                                continue
                            results.append({
                                "event_id": ev["EventId"], "sort_order": r.get("SortOrder") or 0,
                                "rank": r.get("RankNumber") or rank_int(r.get("Rank")),
                                "rank_text": (r.get("Irm") or r.get("Rank") or "").strip() or None,
                                "rider_name": name, "rider_slug": name_to_slug.get(normalize_name(name)),
                                "team": (r.get("TeamName") or "").strip() or None,
                                "nation": (r.get("NationName") or "").strip() or None,
                                "result": (r.get("ResultValue") or "").strip() or None,
                                "uci_points": r.get("PointPcR"),
                            })
            except Exception as e:
                print(f"  ! {c['CompetitionName']}: {e}")
                continue

            label = f"  [{n}/{len(todo)}] {c['CompetitionName'][:40]:<40} {c.get('ClassCode') or '':<6} {len(events):>3} Wertungen {len(results):>5} Zeilen"
            print(label)
            if DRY_RUN:
                for row in results[:3]:
                    print(f"      {row['rank_text']:>4} {row['rider_name']:<26} {row['team'] or '':<28} {row['result'] or '':>10} {row['uci_points']}")
                continue
            db.upsert("races", [race_row], "pcs_slug")
            # alte Wertungen dieses Rennens entfernen (auch fälschlich zugeordnete anderer Kategorien)
            db.delete("race_events", {"race_slug": f"eq.{slug}"})
            if events:
                db.upsert("race_events", events, "id")
                ids = ",".join(str(e["id"]) for e in events)
                db.delete("event_results", {"event_id": f"in.({ids})"})
                # gleiche Sortierposition zweimal (sollte nicht vorkommen) → letzte gewinnt
                uniq = list({(r["event_id"], r["sort_order"]): r for r in results}.values())
                db.upsert("event_results", uniq, "event_id,sort_order")
                # Punkte sofort in die Fantasy-Wertung übernehmen (gleiche Schlüssel wie beim Ranking-Abruf,
                # das wöchentliche Ranking bleibt die Kontrolle und korrigiert ggf.)
                ev_by_id = {e["id"]: e for e in events}
                points = {}
                for r in uniq:
                    if not r["rider_slug"] or not r["uci_points"] or float(r["uci_points"]) <= 0:
                        continue
                    ev = ev_by_id[r["event_id"]]
                    if not ev["event_date"]:
                        continue
                    parts = [p.strip() for p in (ev["stage_name"], ev["event_name"]) if p and p.strip()]
                    label = (" · ".join(dict.fromkeys(parts)) or "Ergebnis")[:200]
                    points[(r["rider_slug"], label)] = {"rider_slug": r["rider_slug"], "race_slug": slug, "label": label,
                                                        "result_date": ev["event_date"], "rank": r["rank"],
                                                        "uci_points": float(r["uci_points"])}
                if points:
                    existing = db.select("results", {"select": "rider_slug,label,result_date,uci_points",
                                                     "race_slug": f"eq.{slug}", "limit": 5000})
                    known = {(r["rider_slug"], r["label"]) for r in existing}
                    # Sicherheitsnetz gegen Doppelzählung: gleiches Ergebnis (Fahrer, Tag, Punkte) unter anderem Namen
                    same = {(r["rider_slug"], r["result_date"], float(r["uci_points"])) for r in existing}
                    points = {k: r for k, r in points.items()
                              if k in known or (r["rider_slug"], r["result_date"], r["uci_points"]) not in same}
                if points:
                    db.upsert("results", list(points.values()), "rider_slug,race_slug,label")
                    recent = (today - timedelta(days=10)).isoformat()
                    fresh = [r for k, r in points.items() if k not in known and r["result_date"] >= recent]
                    if fresh:
                        try:
                            notify_points(fresh, {slug: {"name": race_row["name"]}})
                        except Exception as e:     # Benachrichtigungen dürfen das Laden nie stoppen
                            print(f"  Benachrichtigungen übersprungen: {e}")
            db.update("races", {"pcs_slug": f"eq.{slug}"}, {"loaded_at": datetime.now(timezone.utc).isoformat()})

    if not DRY_RUN:
        n = db.rpc("relink_event_riders")
        print(f"{n} Ergebniszeilen neu mit Fahrern verknüpft.")
        db.rpc("run_maintenance")     # Stichtage, Spieltage abschließen, Stand aktualisieren
    print(f"\nFertig nach {int(time.time() - started) // 60} Minuten.")


if __name__ == "__main__":
    main()
