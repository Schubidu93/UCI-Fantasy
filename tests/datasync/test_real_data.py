"""Echte Antworten von UCI DataRide (Saison 2025, Tour de France Etappe 1), geholt mit dem Workflow
„DataRide-Beispieldaten laden“ (datasync/probe.py). Prüft, dass unsere Umwandlung zu den echten Feldern passt."""
import json
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

from helpers import FakeDb
from dataride import DataRide, ms_date, normalize_name, competition_id
import import_riders
import race_results as rr

FIX = Path(__file__).parent / "fixtures"


def load(name):
    return json.loads((FIX / f"{name}.json").read_text())


class Replay(DataRide):
    """DataRide, das die gespeicherten echten Antworten zurückgibt."""

    def __init__(self):
        super().__init__(pause=0)

    def _call(self, method, path, data):
        if path == "/iframe/GetDisciplineSeasons/":
            return load("seasons")
        if path == "/iframe/RankingsDiscipline/":
            return [{"Rankings": [load("ranking")]}]
        if path == "/iframe/ObjectRankings/":
            return {"data": load("ranking_riders")[data["skip"]:data["skip"] + data["take"]]}
        raise AssertionError(f"unerwartete Abfrage {path}")


class Seasons(unittest.TestCase):
    def test_saison_nach_jahr(self):
        dr = Replay()
        self.assertEqual((dr.season(2025)["Id"], dr.season(2025)["Name"]), (444, "2025"))
        self.assertEqual(dr.season(1990)["Year"], max(s["Year"] for s in load("seasons")))


class Ranking(unittest.TestCase):
    def test_fahrerliste(self):
        db = FakeDb().install()
        with mock.patch.object(import_riders, "DataRide", Replay), mock.patch.object(import_riders, "GENDERS", ["men"]), \
                mock.patch.object(import_riders, "DRY_RUN", False), mock.patch("builtins.print"):
            import_riders.main()
        (_, _, rows, _), = db.of("upsert", "athletes")
        self.assertEqual(len(rows), 20)
        first = rows[0]
        self.assertEqual({k: first[k] for k in ("id", "name", "nation", "team", "pool_rank", "ranking_points", "birth_date")},
                         {"id": "uci-149727", "name": "POGAČAR Tadej", "nation": "SLO", "team": "UAE TEAM EMIRATES XRG",
                          "pool_rank": 1, "ranking_points": 11680.0, "birth_date": "1998-09-21"})
        self.assertEqual([r["pool_rank"] for r in rows], list(range(1, 21)))
        self.assertTrue(all(r["nation"] and len(r["nation"]) == 3 for r in rows), "Ländercodes ohne Leerzeichen")


class TourDeFrance(unittest.TestCase):
    def test_rennen(self):
        tour = load("competitions")[0]
        self.assertEqual((tour["CompetitionName"], tour["ClassCode"]), ("Tour de France", "2.UWT"))
        self.assertEqual((ms_date(tour["StartDate"]), ms_date(tour["EndDate"])), (date(2025, 7, 5), date(2025, 7, 27)))
        self.assertEqual(competition_id(tour["CompetitionName"], 2025, "men"), "tour-de-france/2025")

    def test_etappen(self):
        races = load("races")
        self.assertEqual(sorted(rr.stage_order(r) for r in races), list(range(1, 22)) + [999])
        stage1 = next(r for r in races if r["RaceName"] == "Stage 1")
        self.assertEqual(ms_date(stage1["StartDate"]), date(2025, 7, 5))
        self.assertTrue(all(r["CategoryCode"] == "Men Elite" for r in races))

    def test_wertungen_vollstaendig_nur_hauptwertungen(self):
        tour = load("competitions")[0]
        full = {e["EventName"]: rr.full_list(tour, e) for e in load("events")}
        self.assertEqual({n for n, f in full.items() if f}, {"Stage Classification", "Stage General Classification"})

    def test_ergebniszeilen(self):
        res = load("results")
        rows = [rr.result_row(1, r, {normalize_name("Biniam Girmay"): "uci-1"}) for r in res]
        rows = [r for r in rows if r]
        self.assertEqual(len(rows), len(res))
        first = rows[0]
        self.assertEqual({k: first[k] for k in ("sort_order", "rank", "rank_text", "athlete_name", "athlete_id", "nation", "result")},
                         {"sort_order": 1, "rank": 1, "rank_text": "1", "athlete_name": "GIRMAY Biniam", "athlete_id": "uci-1",
                          "nation": "ERI", "result": "3:53:05"})
        self.assertEqual([r["sort_order"] for r in rows], sorted(r["sort_order"] for r in rows))
        self.assertIsNone(rows[1]["athlete_id"], "unbekannte Fahrer bleiben ohne Verknüpfung")


if __name__ == "__main__":
    unittest.main()
