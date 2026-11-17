"""Umwandlungen und Abrufe aus UCI DataRide (ohne Netz: die Schnittstelle wird nachgebildet)."""
import unittest
from datetime import date

import helpers  # noqa: F401  (Pfad zu datasync/)
from helpers import ms
import dataride
from dataride import DataRide, ms_date, normalize_name, competition_id, athlete_id, slugify


class FakeRide(DataRide):
    """DataRide ohne Netz: Antworten je Pfad aus einer Funktion."""

    def __init__(self, answer):
        super().__init__(pause=0)
        self.answer, self.requests = answer, []

    def _call(self, method, path, data):
        self.requests.append((method, path, dict(data)))
        return self.answer(path, data)


class Dates(unittest.TestCase):
    def test_ms_date(self):
        self.assertEqual(ms_date("/Date(1787868000000)/"), date(2026, 8, 28))
        self.assertEqual(ms_date(ms(date(2025, 1, 1))), date(2025, 1, 1))
        self.assertEqual(ms_date(ms(date(2026, 12, 31))), date(2026, 12, 31))

    def test_kein_datum(self):
        self.assertIsNone(ms_date(None))
        self.assertIsNone(ms_date(""))
        self.assertIsNone(ms_date("/Date(-62135596800000)/"))     # „0001-01-01“


class Names(unittest.TestCase):
    def test_slugs(self):
        self.assertEqual(athlete_id(12345), "uci-12345")
        self.assertEqual(slugify("Tour de France"), "tour-de-france")
        self.assertEqual(slugify("Ronde van Vlaanderen – Tour des Flandres"), "ronde-van-vlaanderen-tour-des-flandres")
        # Gedankenstrich ohne Leerzeichen verbindet die Wörter – so stehen die IDs in der Datenbank, nicht ändern
        self.assertEqual(slugify("Gent–Wevelgem / In Flanders Fields"), "gentwevelgem-in-flanders-fields")

    def test_race_slug_frauen_eigene_id(self):
        self.assertEqual(competition_id("UCI Road World Championships", 2026, "men"), "uci-road-world-championships/2026")
        self.assertEqual(competition_id("UCI Road World Championships", 2026, "women"), "uci-road-world-championships/2026/w")

    def test_normalize_name(self):
        self.assertEqual(normalize_name("POGAČAR Tadej"), "pogacar tadej")
        self.assertEqual(normalize_name("Tadej  Pogacar"), "pogacar tadej")
        self.assertEqual(normalize_name("VAN DER POEL Mathieu"), normalize_name("Mathieu van der Poel"))
        self.assertEqual(normalize_name(None), "")


class Season(unittest.TestCase):
    SEASONS = [{"Id": 1, "Year": 2025, "Name": "2025"}, {"Id": 2, "Year": 2026, "Name": "2026"}]

    def test_jahr_vorhanden(self):
        dr = FakeRide(lambda path, data: self.SEASONS)
        self.assertEqual(dr.season(2025)["Id"], 1)

    def test_jahr_fehlt_neueste(self):
        dr = FakeRide(lambda path, data: self.SEASONS)
        self.assertEqual(dr.season(2030)["Id"], 2)


class Ranking(unittest.TestCase):
    def test_weltrangliste_gefunden(self):
        groups = [{"Rankings": [{"Id": 7, "RankingTypeId": 2, "RankingName": "UCI World Ranking"},
                                {"Id": 8, "RankingTypeId": 1, "RankingName": "UCI World Ranking "}]}]
        dr = FakeRide(lambda path, data: groups)
        self.assertEqual(dr.world_ranking("women", 2)["Id"], 8)
        self.assertEqual(dr.requests[0][2]["filter[filters][1][value]"], dataride.CATEGORY["women"])

    def test_weltrangliste_fehlt(self):
        dr = FakeRide(lambda path, data: [{"Rankings": []}])
        with self.assertRaises(RuntimeError):
            dr.world_ranking("men", 2)

    def test_fahrer_seitenweise_bis_limit(self):
        def answer(path, data):
            skip = data["skip"]
            return {"data": [{"Rank": skip + i + 1} for i in range(data["take"]) if skip + i < 450]}
        dr = FakeRide(answer)
        rk = {"Id": 8, "RankingTypeId": 1, "MomentId": 3}
        self.assertEqual(len(dr.ranking_riders(rk, "men", 2, limit=1000, page_size=200)), 450)
        self.assertEqual([r[2]["skip"] for r in dr.requests], [0, 200, 400])
        self.assertEqual(len(dr.ranking_riders(rk, "men", 2, limit=300, page_size=200)), 300)


class Results(unittest.TestCase):
    """Ergebnisliste: Top 25 plus alle weiteren Plätze mit UCI-Punkten."""

    @staticmethod
    def ride(n, points_until):
        rows = [{"SortOrder": i, "PointPcR": 10 if i <= points_until else 0} for i in range(1, n + 1)]
        return FakeRide(lambda path, data: {"data": rows[data["skip"]:data["skip"] + data["take"]]})

    def test_top25_und_punkteplaetze(self):
        dr = self.ride(150, points_until=40)
        out = dr.results(1)
        self.assertEqual([r["SortOrder"] for r in out], list(range(1, 41)))
        self.assertEqual(len(dr.requests), 2, "nach der ersten Seite ohne Punkte jenseits Platz 25 aufhören")

    def test_punkte_auf_zweiter_seite(self):
        dr = self.ride(250, points_until=120)
        out = dr.results(1)
        self.assertEqual(len(out), 120)
        self.assertEqual(len(dr.requests), 3)

    def test_vollstaendig(self):
        dr = self.ride(150, points_until=10)
        self.assertEqual(len(dr.results(1, keep_top=None)), 150)


if __name__ == "__main__":
    unittest.main()
