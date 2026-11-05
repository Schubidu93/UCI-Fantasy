"""
Fahrerliste aus der UCI-Weltrangliste (UCI DataRide) in die Tabelle riders laden.
Rang (uci_rank) bestimmt beim Live-Draft die Aufruf-Reihenfolge und hilft beim
Filtern freier Fahrer. Neue Fahrer im Ranking sind damit automatisch frei.

DRY_RUN=1 → nur anzeigen, nichts speichern.
"""
import os
from datetime import datetime, timezone

from dataride import DataRide, ms_date, rider_slug

DRY_RUN = os.environ.get("DRY_RUN") == "1"
MAX_RIDERS = 6000           # alle Fahrer mit UCI-Punkten (Männer ca. 3400, Frauen weniger)
GENDERS = os.environ.get("GENDERS", "men,women").split(",")


def main():
    dr = DataRide()
    season = dr.season()
    print(f"Saison {season['Name']} (ID {season['Id']})")
    now = datetime.now(timezone.utc).isoformat()
    for gender in GENDERS:
        rk = dr.world_ranking(gender, season["Id"])
        rows = dr.ranking_riders(rk, gender, season["Id"], MAX_RIDERS)
        riders = [{
            "pcs_slug": rider_slug(r["ObjectId"]),
            "name": (r.get("DisplayName") or r.get("IndividualFullName") or "").strip(),
            "gender": gender,
            "nation": (r.get("NationName") or "").strip() or None,
            "team": (r.get("TeamName") or "").strip() or None,
            "uci_rank": r.get("Rank"),
            "ranking_points": r.get("Points"),
            "birth_date": (ms_date(r.get("BirthDate")) or None) and ms_date(r.get("BirthDate")).isoformat(),
            "updated_at": now,
        } for r in rows if r.get("ObjectId") and r.get("DisplayName")]
        print(f"{gender}: {rk['RankingName']} – {len(riders)} Fahrer")
        for r in riders[:5]:
            print(f"  #{r['uci_rank']:>4} {r['name']:<28} {r['team'] or '':<32} {r['nation'] or ''} {r['ranking_points']}")
        if DRY_RUN or not riders:
            continue
        import db
        db.upsert("riders", riders, "pcs_slug")
        # aus den Top-Plätzen gefallene Fahrer behalten ihren Eintrag ohne Rang
        db.update("riders", {"gender": f"eq.{gender}", "updated_at": f"lt.{now}"}, {"uci_rank": None})
        print("  gespeichert.")
    if not DRY_RUN:
        import db
        print(f"{db.rpc('relink_event_riders')} Ergebniszeilen neu mit Fahrern verknüpft.")


if __name__ == "__main__":
    main()
