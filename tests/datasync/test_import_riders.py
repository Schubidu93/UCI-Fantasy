"""Fahrerliste aus der UCI-Weltrangliste."""
import unittest
from unittest import mock

from helpers import FakeDb
import import_riders


class FakeRanking:
    def season(self):
        return {"Id": 2, "Name": "2026", "Year": 2026}

    def world_ranking(self, gender, season_id):
        return {"Id": 8, "RankingTypeId": 1, "MomentId": 3, "RankingName": "UCI World Ranking"}

    def ranking_riders(self, rk, gender, season_id, limit):
        return [
            {"ObjectId": 1, "DisplayName": "POGAČAR Tadej ", "NationName": "Slovenia", "TeamName": "UAE Team Emirates XRG",
             "Rank": 1, "Points": 11680, "BirthDate": "/Date(906760800000)/"},
            {"ObjectId": 2, "DisplayName": "OHNE Team", "NationName": "", "TeamName": " ", "Rank": 2, "Points": 10,
             "BirthDate": "/Date(-62135596800000)/"},
            {"ObjectId": None, "DisplayName": "Ohne ID"},
            {"ObjectId": 3, "DisplayName": ""},
        ]


class ImportRiders(unittest.TestCase):
    def test_speichert_und_nimmt_rang_weg(self):
        db = FakeDb().install()
        with mock.patch.object(import_riders, "DataRide", FakeRanking), \
                mock.patch.object(import_riders, "GENDERS", ["men"]), mock.patch.object(import_riders, "DRY_RUN", False), \
                mock.patch("builtins.print"):
            import_riders.main()
        (_, _, rows, key), = db.of("upsert", "riders")
        self.assertEqual(key, "pcs_slug")
        self.assertEqual([r["pcs_slug"] for r in rows], ["uci-1", "uci-2"])
        first, second = rows
        self.assertEqual((first["name"], first["nation"], first["birth_date"], first["uci_rank"]),
                         ("POGAČAR Tadej", "Slovenia", "1998-09-26", 1))
        self.assertEqual((second["nation"], second["team"], second["birth_date"]), (None, None, None))
        (_, _, filters, values), = db.of("update", "riders")
        self.assertEqual((filters["gender"], filters["updated_at"], values),
                         ("eq.men", f"lt.{first['updated_at']}", {"uci_rank": None}))
        self.assertEqual([c[1] for c in db.of("rpc")], ["relink_event_riders", "results_from_events"])


if __name__ == "__main__":
    unittest.main()
