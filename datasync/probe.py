"""
Echte Beispieldaten von UCI DataRide für die Tests holen (tests/datasync/fixtures/).

Läuft nur über den Workflow „DataRide-Beispieldaten laden“ (probe-dataride.yml), weil DataRide aus der
Claude-Umgebung nicht erreichbar ist. Wenige Abfragen, ehrliche Kennung, Pausen wie im normalen Abruf.
"""
import json
from pathlib import Path

from dataride import DataRide

OUT = Path(__file__).resolve().parents[1] / "tests" / "datasync" / "fixtures"
YEAR = 2025
RACE = "Tour de France"


def save(name, data):
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / f"{name}.json").write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    print(f"  {name}.json")


def main():
    dr = DataRide()
    seasons = dr._call("GET", "/iframe/GetDisciplineSeasons/", {"disciplineId": 10})
    save("seasons", seasons)
    season = dr.season(YEAR)
    rk = dr.world_ranking("men", season["Id"])
    save("ranking", rk)
    save("ranking_riders", dr.ranking_riders(rk, "men", season["Id"], limit=20, page_size=20))
    comps = dr.competitions("men", season["Id"])
    tour = next(c for c in comps if c.get("CompetitionName", "").strip().startswith(RACE))
    save("competitions", [tour] + [c for c in comps if c is not tour][:20])
    races = dr.races(tour["CompetitionId"])
    save("races", races)
    stage = next(r for r in races if "1" in (r.get("RaceName") or "")) if races else None
    events = dr.events(stage["Id"])
    save("events", events)
    ev = events[0]
    save("results", dr.results(ev["EventId"], keep_top=None)[:60])


if __name__ == "__main__":
    main()
