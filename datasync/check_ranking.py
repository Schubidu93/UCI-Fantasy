"""
Abgleich: Punkte der UCI-Weltrangliste je Fahrer gegen unsere gespeicherten Rennpunkte (Tabelle results).
Zeigt pro Fahrer die Einzelergebnisse, die nur in der Rangliste bzw. nur bei uns stehen.

FAHRER=20         die besten N Fahrer je Wertung (Standard 20)
GENDERS=men       welche Wertungen
FIX=1             statt der besten N nur Fahrer mit Abweichung prüfen und fehlende Punkte nachtragen
                  (z. B. Mannschafts-Wertungen wie die Mixed-Staffel, die in keiner Einzel-Ergebnisliste stehen)
"""
import os
import re
from collections import Counter
from datetime import datetime, timedelta

import db
from dataride import DataRide, competition_id

N = int(os.environ.get("FAHRER") or 20)
FIX = os.environ.get("FIX") == "1"
GENDERS = (os.environ.get("GENDERS") or "men,women").split(",")


def day_of(row):
    try:
        return datetime.strptime(row.get("Date", ""), "%d %b %Y").date()
    except ValueError:
        m = re.search(r"(\d{10,})", row.get("StartDate") or "")
        return (datetime(1970, 1, 1) + timedelta(milliseconds=int(m.group(1)) + 12 * 3600 * 1000)).date() if m else None


def add_missing(r, gender, uci, only_uci):
    """Fehlende Einzelpunkte aus der Rangliste in unsere Wertung übernehmen."""
    rows, races = [], {}
    for (d, p), n in only_uci.items():
        for u in [u for u in uci if (u[0], u[1]) == (d, p)][:n]:
            x = u[3]
            comp = (x.get("CompetitionName") or "Unbekanntes Rennen").strip()
            slug = competition_id(comp, int(d[:4]), gender)
            races[slug] = {"id": slug, "name": comp, "gender": gender, "category": x.get("ClassCode"),
                           "start_date": d, "end_date": d}
            parts = [s.strip() for s in (x.get("RaceName"), x.get("EventName")) if s and s.strip()]
            rows.append({"athlete_id": r["id"], "competition_id": slug, "label": (" · ".join(dict.fromkeys(parts)) or "Ergebnis")[:200],
                         "result_date": d, "rank": x.get("Rank") if isinstance(x.get("Rank"), int) else None, "points": p})
    known = {x["id"] for x in db.select("competitions", {"select": "id", "id": f"in.({','.join(races)})"})}
    new_races = [v for k, v in races.items() if k not in known]
    if new_races:
        db.upsert("competitions", new_races, "id")
    db.upsert("results", rows, "athlete_id,competition_id,label")
    print(f"      → {len(rows)} fehlende Ergebnisse nachgetragen")


def main():
    dr = DataRide()
    season = dr.season()
    for g in GENDERS:
        rk = dr.world_ranking(g, season["Id"])
        if FIX:
            slugs = [m["athlete_id"] for m in db.rpc("ranking_mismatch", {"p_limit": 400}) if m["gender"] == g]
            riders = []
            for i in range(0, len(slugs), 100):
                riders += db.select("athletes", {"select": "id,name,ranking_points", "id": f"in.({','.join(slugs[i:i + 100])})"})
        else:
            riders = db.select("athletes", {"select": "id,name,ranking_points", "gender": f"eq.{g}",
                                          "pool_rank": "not.is.null", "order": "pool_rank", "limit": N})
        print(f"\n=== {g}: {rk['RankingName']} ===")
        for r in riders:
            rows = dr.rider_results(rk, g, season["Id"], int(r["id"].split("-", 1)[1]))
            uci = []
            for x in rows:
                pts = float(x.get("Points") or 0)
                d = day_of(x)
                if pts > 0 and d and not x.get("IsInvalidResult"):
                    uci.append((d.isoformat(), round(pts, 2), f"{(x.get('CompetitionName') or '').strip()} · {x.get('RaceName') or ''} · {x.get('EventName') or ''}", x))
            if not uci:
                continue
            lo, hi = min(u[0] for u in uci), max(u[0] for u in uci)
            ours = db.select("results", {"select": "result_date,points,competition_id,label", "athlete_id": f"eq.{r['id']}",
                                         "result_date": f"gte.{lo}", "limit": 2000})
            ours = [(o["result_date"], round(float(o["points"]), 2), f"{o['competition_id']} · {o['label']}") for o in ours if o["result_date"] <= hi]
            cu, co = Counter((u[0], u[1]) for u in uci), Counter((o[0], o[1]) for o in ours)
            only_uci, only_ours = cu - co, co - cu
            su, so = sum(u[1] for u in uci), sum(o[1] for o in ours)
            flag = "OK " if not only_uci and not only_ours else "DIFF"
            print(f"{flag} {r['name']:<28} Rangliste {su:9.2f}  bei uns {so:9.2f}  ({lo} … {hi})")
            for (d, p), n in sorted(only_uci.items()):
                names = [u[2] for u in uci if (u[0], u[1]) == (d, p)]
                print(f"      nur Rangliste: {d} {p:7.2f} ×{n}  {names[0][:90]}")
            if FIX and only_uci:
                add_missing(r, g, uci, only_uci)
            for (d, p), n in sorted(only_ours.items()):
                names = [o[2] for o in ours if (o[0], o[1]) == (d, p)]
                print(f"      nur bei uns:   {d} {p:7.2f} ×{n}  {names[0][:90]}")


if __name__ == "__main__":
    main()
