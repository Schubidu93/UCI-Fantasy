"""
Täglicher Abruf: holt für alle Fahrer, die in einem Fantasy-Kader stehen, die
Ergebnisse mit UCI-Punkten aus UCI DataRide und speichert sie in results.
Aberkannte Ergebnisse (IsInvalidResult bzw. nicht mehr gelistet) werden entfernt;
eingefrorene Spieltage bleiben davon unberührt.
Danach rechnet die Datenbank Stichtage ab und schließt/friert Spieltage ein.

Hinweis: Die UCI rechnet das Ranking wöchentlich neu – neue Punkte erscheinen
also mit bis zu einer Woche Verzögerung.

MODE=alle → Ergebnisse aller Fahrer der Weltrangliste (dauert ca. 40 Minuten,
läuft wöchentlich), sonst nur Fahrer in Kadern (täglich).
DRY_RUN=1 → nur anzeigen, nichts speichern (TEST_RIDERS=uci-149727,… zum Testen).
"""
import os
from datetime import date, timedelta

from dataride import DataRide, object_id, result_row

DRY_RUN = os.environ.get("DRY_RUN") == "1"
NACHLAUF_TAGE = 14     # abgegebene Fahrer noch so lange prüfen (späte Korrekturen)
LOESCH_FENSTER = 300   # nur so junge Ergebnisse löschen, wenn sie verschwinden (Ranking rolliert über 52 Wochen)
BLOCK = 100            # Fahrer pro Speicher-Block


def owned_riders(today):
    import db
    since = (today - timedelta(days=NACHLAUF_TAGE)).isoformat()
    rows = db.select("roster_entries", {"select": "rider_slug", "or": f"(released_on.is.null,released_on.gte.{since})"})
    return sorted({r["rider_slug"] for r in rows if r["rider_slug"].startswith("uci-")})


def ranked_riders():
    """Alle Fahrer mit aktuellem UCI-Rang (seitenweise, die API liefert max. 1000 Zeilen)."""
    import db
    out = []
    while True:
        rows = db.select("riders", {"select": "pcs_slug,gender", "uci_rank": "not.is.null", "order": "pcs_slug",
                                    "limit": 1000, "offset": len(out)})
        out += rows
        if len(rows) < 1000:
            return out


def notify_points(fresh, races):
    """Neue Punkte an die Besitzer der Fahrer melden (eine Nachricht pro Nutzer und Liga)."""
    import db
    from collections import defaultdict
    if not fresh:
        return
    slugs = sorted({r["rider_slug"] for r in fresh})
    owners = []
    for i in range(0, len(slugs), 50):
        owners += db.select("roster_entries", {"select": "league_id,manager_id,rider_slug",
                                               "rider_slug": f"in.({','.join(slugs[i:i + 50])})", "released_on": "is.null"})
    if not owners:
        return
    mgr_ids = sorted({o["manager_id"] for o in owners})
    managers = {m["id"]: m for m in db.select("managers", {"select": "id,user_id", "id": f"in.({','.join(mgr_ids)})"})}
    users = sorted({m["user_id"] for m in managers.values() if m.get("user_id")})
    if not users:
        return
    subscribed = {s["user_id"] for s in db.select("push_subscriptions", {"select": "user_id", "user_id": f"in.({','.join(users)})"})}
    names = {r["pcs_slug"]: r["name"] for r in db.select("riders", {"select": "pcs_slug,name", "pcs_slug": f"in.({','.join(slugs)})"})}
    by_rider = defaultdict(list)
    for r in fresh:
        by_rider[r["rider_slug"]].append(r)
    msgs = defaultdict(list)          # (user, liga) → Zeilen
    for o in owners:
        user = managers.get(o["manager_id"], {}).get("user_id")
        if user in subscribed:
            for r in by_rider[o["rider_slug"]]:
                msgs[(user, o["league_id"])].append(r)
    out = []
    for (user, league), rows in msgs.items():
        total = sum(r["uci_points"] for r in rows)
        top = sorted(rows, key=lambda r: -r["uci_points"])[:3]
        body = ", ".join(f"{names.get(r['rider_slug'], r['rider_slug']).split(' ')[0].title()} +{r['uci_points']:g} "
                         f"({races.get(r['race_slug'], {}).get('name', r['race_slug'])})" for r in top)
        if len(rows) > 3:
            body += f" und {len(rows) - 3} weitere"
        out.append({"user_id": user, "title": f"🏆 +{total:g} UCI-Punkte für dein Team", "body": body,
                    "url": f"#/league/{league}/team"})
    if out:
        db.insert("notifications", out)
        print(f"{len(out)} Punkte-Benachrichtigungen vorgemerkt.")


def fetch_block(dr, block, genders, rankings, season):
    races, results, fetched = {}, [], set()
    for slug in block:
        g = genders.get(slug, "men")
        try:
            rows = dr.rider_results(rankings[g], g, season["Id"], object_id(slug))
        except Exception as e:
            print(f"  {slug}: Fehler – {e}")
            continue
        fetched.add(slug)
        for row in rows:
            conv = result_row(row, g)
            if not conv:
                continue
            race, res = conv
            r = races.setdefault(race["pcs_slug"], {"pcs_slug": race["pcs_slug"], "name": race["name"], "gender": g,
                                                    "uci_class": race["uci_class"], "start_date": race["date"], "end_date": race["date"]})
            r["start_date"], r["end_date"] = min(r["start_date"], race["date"]), max(r["end_date"], race["date"])
            results.append({**res, "rider_slug": slug})
    for r in races.values():
        r["start_date"], r["end_date"] = r["start_date"].isoformat(), r["end_date"].isoformat()
    # doppelte Schlüssel zusammenfassen (gleiches Rennen/Label kommt nicht doppelt in einen Upsert)
    results = list({(r["rider_slug"], r["race_slug"], r["label"]): r for r in results}.values())
    return races, results, fetched


def save_block(races, results, fetched, today):
    import db
    # bisher gespeicherte Ergebnisse (für "neue Punkte"-Benachrichtigungen und die Delta-Korrektur)
    since = (today - timedelta(days=LOESCH_FENSTER)).isoformat()
    existing = []
    fetched = sorted(fetched)
    for i in range(0, len(fetched), 10):   # 10 Fahrer pro Abfrage bleiben sicher unter 1000 Zeilen
        existing += db.select("results", {"select": "id,rider_slug,race_slug,label",
                                          "rider_slug": f"in.({','.join(fetched[i:i + 10])})",
                                          "result_date": f"gte.{since}"})
    known = {(r["rider_slug"], r["race_slug"], r["label"]) for r in existing}

    db.upsert("races", list(races.values()), "pcs_slug")
    db.upsert("results", results, "rider_slug,race_slug,label")

    if os.environ.get("MODE") != "alle":
        recent = (today - timedelta(days=10)).isoformat()
        fresh = [r for r in results if (r["rider_slug"], r["race_slug"], r["label"]) not in known and r["result_date"] >= recent]
        try:
            notify_points(fresh, races)
        except Exception as e:     # Benachrichtigungen dürfen den Abruf nie scheitern lassen
            print(f"Benachrichtigungen übersprungen: {e}")

    # Delta-Korrektur: junge Ergebnisse, die bei der UCI nicht mehr auftauchen (z. B. aberkannt)
    current = {(r["rider_slug"], r["race_slug"], r["label"]) for r in results}
    stale = [r["id"] for r in existing if (r["rider_slug"], r["race_slug"], r["label"]) not in current]
    for i in range(0, len(stale), 200):
        db.delete("results", {"id": f"in.({','.join(map(str, stale[i:i + 200]))})"})
    if stale:
        print(f"{len(stale)} nicht mehr gültige Ergebnisse entfernt.")



def main():
    today = date.today()
    if DRY_RUN:
        slugs = [s for s in os.environ.get("TEST_RIDERS", "").split(",") if s]
        genders = {s: os.environ.get("TEST_GENDER", "men") for s in slugs}
    elif os.environ.get("MODE") == "alle":
        import db
        riders = [r for r in ranked_riders() if r["pcs_slug"].startswith("uci-")]
        slugs = sorted(set(owned_riders(today)) | {r["pcs_slug"] for r in riders})
        genders = {r["pcs_slug"]: r["gender"] for r in riders}
        missing = [x for x in slugs if x not in genders]
        for i in range(0, len(missing), 100):
            chunk = missing[i:i + 100]
            genders.update({r["pcs_slug"]: r["gender"] for r in db.select(
                "riders", {"select": "pcs_slug,gender", "pcs_slug": f"in.({','.join(chunk)})"})})
    else:
        import db
        slugs = owned_riders(today)
        genders = {}
        for i in range(0, len(slugs), 100):
            chunk = slugs[i:i + 100]
            genders.update({r["pcs_slug"]: r["gender"] for r in db.select(
                "riders", {"select": "pcs_slug,gender", "pcs_slug": f"in.({','.join(chunk)})"})})
    print(f"{len(slugs)} Fahrer {'insgesamt' if os.environ.get('MODE') == 'alle' else 'in Kadern'}.")
    if not slugs:
        if not DRY_RUN:
            db.rpc("run_maintenance")
        return

    dr = DataRide()
    season = dr.season()
    rankings = {g: dr.world_ranking(g, season["Id"]) for g in sorted(set(genders.values()))}
    print(f"Saison {season['Name']}, Ranglisten-Stand: " + ", ".join(f"{g} Moment {r['MomentId']}" for g, r in rankings.items()))

    # in Blöcken zu 100 Fahrern abrufen und sofort speichern (ein Abbruch verliert nichts)
    total_races, total_results = 0, 0
    for b in range(0, len(slugs), BLOCK):
        block = slugs[b:b + BLOCK]
        races, results, fetched = fetch_block(dr, block, genders, rankings, season)
        total_races += len(races)
        total_results += len(results)
        print(f"  … {min(b + BLOCK, len(slugs))}/{len(slugs)} Fahrer: {len(results)} Ergebnisse")
        if DRY_RUN:
            for r in sorted(results, key=lambda x: x["result_date"], reverse=True)[:15]:
                print(f"  {r['result_date']} {r['rider_slug']:<12} {races[r['race_slug']]['name'][:30]:<30} {r['label'][:45]:<45} {r['uci_points']:>7}")
            continue
        save_block(races, results, fetched, today)
    print(f"Fertig: {total_results} Ergebnisse aus {total_races} Rennen (je Block gezählt).")
    if DRY_RUN:
        return

    db.rpc("run_maintenance")
    print("Spieltage aktualisiert.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        if not DRY_RUN:
            import db
            try:
                db.update("sync_status", {"id": "eq.1"}, {"ok": False, "message": str(e)[:500]})
            finally:
                raise
        raise
