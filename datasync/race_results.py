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
from collections import defaultdict
from datetime import date, datetime, timedelta, timezone

from dataride import DataRide, ms_date, normalize_name, race_slug

DRY_RUN = os.environ.get("DRY_RUN") == "1"
GENDERS = os.environ.get("GENDERS", "men,women").split(",")
LIMIT = int(os.environ.get("LIMIT", "0") or 0)
REFRESH = os.environ.get("REFRESH") == "1"
CLASSES = {c for c in os.environ.get("CLASSES", "").split(",") if c}
CATEGORY_NAME = {"men": "Men Elite", "women": "Women Elite"}
FERTIG_NACH_TAGEN = 21     # nach so vielen Tagen gilt ein Ergebnis als endgültig (ein letzter Abgleich danach)
# Täglich nur Rennen der letzten Tage nachladen; mittwochs alle der letzten 3 Wochen (Korrekturen der UCI)
FENSTER = int(os.environ.get("FENSTER") or (FERTIG_NACH_TAGEN if date.today().weekday() == 2 else 3))


def replace_provisional(gender, cal, today):
    """Vorläufige Kalendereinträge (von Hand, provisional=true) löschen, sobald DataRide das Rennen liefert:
    gleiche Klasse und Start höchstens 3 Tage auseinander. Abgelaufene Platzhalter ebenfalls entfernen."""
    import db
    prov = db.select("races", {"select": "pcs_slug,uci_class,start_date,end_date", "gender": f"eq.{gender}",
                               "provisional": "is.true", "limit": 500})
    gone = []
    for p in prov:
        start = date.fromisoformat(p["start_date"])
        end = date.fromisoformat(p["end_date"] or p["start_date"])
        if end < today - timedelta(days=7) or any(
                c["uci_class"] == p["uci_class"] and abs((date.fromisoformat(c["start_date"]) - start).days) <= 3
                for c in cal):
            gone.append(p["pcs_slug"])
    for slug in gone:
        db.delete("races", {"pcs_slug": f"eq.{slug}", "provisional": "is.true"})
    if gone:
        print(f"  {len(gone)} vorläufige Kalendereinträge durch DataRide ersetzt bzw. entfernt")


def save_points(slug, race_name, events, rows, today):
    """UCI-Punkte der geladenen Wertungen in die Fantasy-Wertung (Tabelle results) übernehmen.
    Ergebnisse dieses Rennens, die es im neu geladenen Zeitraum nicht mehr gibt (z. B. aberkannt),
    werden entfernt; eingefrorene Spieltage sind davon nicht betroffen (eigener Schnappschuss)."""
    import db
    ev_by_id = {e["id"]: e for e in events}
    points = {}
    for r in rows:
        ev = ev_by_id[r["event_id"]]
        if not r["rider_slug"] or not r["uci_points"] or float(r["uci_points"]) <= 0 or not ev["event_date"]:
            continue
        parts = [p.strip() for p in (ev["stage_name"], ev["event_name"]) if p and p.strip()]
        label = (" · ".join(dict.fromkeys(parts)) or "Ergebnis")[:200]
        points[(r["rider_slug"], label)] = {"rider_slug": r["rider_slug"], "race_slug": slug, "label": label,
                                            "result_date": ev["event_date"], "rank": r["rank"],
                                            "uci_points": float(r["uci_points"])}
    dates = [e["event_date"] for e in events if e["event_date"]]
    if not dates:
        return
    existing = db.select("results", {"select": "id,rider_slug,label,result_date,uci_points", "race_slug": f"eq.{slug}",
                                     "result_date": f"gte.{min(dates)}", "limit": 5000})
    stale = [r["id"] for r in existing if (r["rider_slug"], r["label"]) not in points]
    for i in range(0, len(stale), 200):
        db.delete("results", {"id": f"in.({','.join(map(str, stale[i:i + 200]))})"})
    if points:
        db.upsert("results", list(points.values()), "rider_slug,race_slug,label")
    # Benachrichtigung nur für wirklich neue Punkte der letzten 10 Tage
    seen = {(r["rider_slug"], r["result_date"], float(r["uci_points"])) for r in existing}
    recent = (today - timedelta(days=10)).isoformat()
    fresh = [r for r in points.values() if r["result_date"] >= recent
             and (r["rider_slug"], r["result_date"], r["uci_points"]) not in seen]
    if fresh:
        try:
            notify_points(fresh, race_name)
        except Exception as e:     # Benachrichtigungen dürfen das Laden nie stoppen
            print(f"  Benachrichtigungen übersprungen: {e}")


def notify_points(fresh, race_name):
    """Neue Punkte an die Besitzer der Fahrer melden (eine Nachricht pro Nutzer und Liga)."""
    import db
    slugs = sorted({r["rider_slug"] for r in fresh})
    owners = db.select("roster_entries", {"select": "league_id,manager_id,rider_slug",
                                          "rider_slug": f"in.({','.join(slugs)})", "released_on": "is.null"})
    if not owners:
        return
    managers = {m["id"]: m for m in db.select("managers", {
        "select": "id,user_id", "id": f"in.({','.join(sorted({o['manager_id'] for o in owners}))})"})}
    users = sorted({m["user_id"] for m in managers.values() if m.get("user_id")})
    if not users:
        return
    subscribed = {s["user_id"] for s in db.select("push_subscriptions", {"select": "user_id", "user_id": f"in.({','.join(users)})"})}
    names = {r["pcs_slug"]: r["name"] for r in db.select("riders", {"select": "pcs_slug,name", "pcs_slug": f"in.({','.join(slugs)})"})}
    msgs = defaultdict(list)          # (Nutzer, Liga) → Ergebnisse
    for o in owners:
        user = managers.get(o["manager_id"], {}).get("user_id")
        if user in subscribed:
            msgs[(user, o["league_id"])] += [r for r in fresh if r["rider_slug"] == o["rider_slug"]]
    out = []
    for (user, league), rows in msgs.items():
        total = sum(r["uci_points"] for r in rows)
        top = sorted(rows, key=lambda r: -r["uci_points"])[:3]
        body = ", ".join(f"{names.get(r['rider_slug'], r['rider_slug']).split(' ')[0].title()} +{r['uci_points']:g}" for r in top)
        if len(rows) > 3:
            body += f" und {len(rows) - 3} weitere"
        out.append({"user_id": user, "title": f"🏆 +{total:g} UCI-Punkte · {race_name}", "body": body,
                    "url": f"#/league/{league}/team"})
    if out:
        db.insert("notifications", out)
        print(f"  {len(out)} Punkte-Benachrichtigungen vorgemerkt.")


# Vollständige Ergebnislisten (statt Top 25 + Plätze mit Punkten) für die wichtigsten Rennen –
# nur Etappen-, Gesamt- und Tagesergebnis, Nebenwertungen (Punkte, Berg, Nachwuchs, Team) bleiben gekürzt
FULL_CLASSES = {"1.UWT", "2.UWT", "1.WWT", "2.WWT", "1.Pro", "2.Pro", "CM"}


def full_list(comp, ev):
    return comp.get("ClassCode") in FULL_CLASSES and not re.search(
        r"Points|Mountain|Young|Youth|Team|Sprint|Combativ", ev.get("EventName") or "", re.I)


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
            replace_provisional(gender, cal, today)
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
            slug = race_slug(c["CompetitionName"], (start or today).year, gender)
            race_row = {"pcs_slug": slug, "name": c["CompetitionName"].strip(), "gender": gender,
                        "uci_class": c.get("ClassCode"), "country": c.get("CountryIsoCode3"),
                        "dataride_id": c["CompetitionId"],
                        "start_date": start.isoformat() if start else None, "end_date": end.isoformat() if end else None}
            events, results = [], []
            # Rundfahrten: ältere, schon gespeicherte Etappen nicht jedes Mal neu abfragen
            full = DRY_RUN or c["CompetitionId"] in final_pass
            have = set() if full else {e["stage_name"] for e in db.select(
                "race_events", {"select": "stage_name", "race_slug": f"eq.{slug}", "limit": 2000})}
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
                        events.append({"id": ev["EventId"], "race_slug": slug, "stage_name": race.get("RaceName"),
                                       "stage_no": stage_order(race), "event_name": ev.get("EventName") or "",
                                       "event_date": day.isoformat() if day else None,
                                       "winner": ev.get("WinnerName") or ev.get("IndividualWinner")})
                        for r in dr.results(ev["EventId"], keep_top=None if full_list(c, ev) else 25):
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

            label = f"  [{n}/{len(todo)}] {c['CompetitionName'][:40]:<40} {c.get('ClassCode') or '':<6} {len(events):>3} Wertungen {len(results):>5} Zeilen" + (f" ({skipped} ältere Etappen übersprungen)" if skipped else "")
            print(label)
            if DRY_RUN:
                for row in results[:3]:
                    print(f"      {row['rank_text']:>4} {row['rider_name']:<26} {row['team'] or '':<28} {row['result'] or '':>10} {row['uci_points']}")
                continue
            db.upsert("races", [race_row], "pcs_slug")
            # alte Wertungen dieses Rennens entfernen (auch fälschlich zugeordnete anderer Kategorien) –
            # bei nur teilweise geladenen Rundfahrten bleiben die übersprungenen Etappen stehen
            if not skipped:
                db.delete("race_events", {"race_slug": f"eq.{slug}"})
            if events:
                db.upsert("race_events", events, "id")
                ids = ",".join(str(e["id"]) for e in events)
                db.delete("event_results", {"event_id": f"in.({ids})"})
                # gleiche Sortierposition zweimal (sollte nicht vorkommen) → letzte gewinnt
                uniq = list({(r["event_id"], r["sort_order"]): r for r in results}.values())
                db.upsert("event_results", uniq, "event_id,sort_order")
                save_points(slug, race_row["name"], events, uniq, today)
            db.update("races", {"pcs_slug": f"eq.{slug}"}, {"loaded_at": datetime.now(timezone.utc).isoformat()})

    if not DRY_RUN:
        n = db.rpc("relink_event_riders")
        print(f"{n} Ergebniszeilen neu mit Fahrern verknüpft.")
        print(f"{db.rpc('results_from_events')} fehlende Punkte-Ergebnisse nachgetragen.")
        for y in sorted({today.year, today.year - 1, season["Year"]}):
            if y >= FIRST_YEAR:
                db.rpc("refresh_season_stats", {"p_year": y})
        db.rpc("run_maintenance")     # Stichtage, Spieltage abschließen, Stand aktualisieren
        db.update("sync_status", {"id": "eq.1"}, {"last_run": datetime.now(timezone.utc).isoformat(), "ok": True, "message": None})
    print(f"\nFertig nach {int(time.time() - started) // 60} Minuten.")


if __name__ == "__main__":
    main()
