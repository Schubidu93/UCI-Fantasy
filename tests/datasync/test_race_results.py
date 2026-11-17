"""Rennen und Ergebnislisten: Hilfsfunktionen und Übernahme der UCI-Punkte in die Wertung (results)."""
import unittest
from datetime import date

from helpers import FakeDb
import race_results as rr

TODAY = date(2026, 11, 17)


class Helpers(unittest.TestCase):
    def test_rank_int(self):
        self.assertEqual(rr.rank_int("12"), 12)
        self.assertEqual(rr.rank_int(" 3 "), 3)
        self.assertIsNone(rr.rank_int("DNF"))
        self.assertIsNone(rr.rank_int(None))

    def test_stage_order(self):
        self.assertEqual(rr.stage_order({"RaceName": "Prologue"}), 0)
        self.assertEqual(rr.stage_order({"RaceName": "Stage 12 - Pau > Hautacam"}), 12)
        self.assertEqual(rr.stage_order({"RaceName": "General Classification"}), 999)
        self.assertEqual(rr.stage_order({}), 999)

    def test_full_list_nur_hauptwertungen_grosser_rennen(self):
        wt = {"ClassCode": "2.UWT"}
        self.assertTrue(rr.full_list(wt, {"EventName": "Stage Classification"}))
        self.assertTrue(rr.full_list(wt, {"EventName": "General Classification"}))
        for side in ("Points Classification", "Mountain Classification", "Young Rider", "Team Classification"):
            self.assertFalse(rr.full_list(wt, {"EventName": side}), side)
        self.assertFalse(rr.full_list({"ClassCode": "1.2"}, {"EventName": "Result"}))
        self.assertTrue(rr.full_list({"ClassCode": "CM"}, {"EventName": "Result"}))


class SavePoints(unittest.TestCase):
    EVENTS = [
        {"id": 1, "stage_name": "Stage 1", "event_name": "Stage Classification", "event_date": "2026-07-04"},
        {"id": 2, "stage_name": "Stage 1", "event_name": "Stage 1", "event_date": "2026-07-04"},
        {"id": 3, "stage_name": "Stage 2", "event_name": "Stage Classification", "event_date": None},
    ]

    def row(self, event_id, slug, pts, rank=1):
        return {"event_id": event_id, "athlete_id": slug, "points": pts, "rank": rank}

    def test_punkte_uebernehmen_und_veraltete_entfernen(self):
        existing = [
            {"id": 10, "athlete_id": "uci-1", "label": "Stage 1 · Stage Classification", "result_date": "2026-07-04", "points": 50},
            {"id": 11, "athlete_id": "uci-9", "label": "Stage 1 · Stage Classification", "result_date": "2026-07-04", "points": 20},
            {"id": 12, "athlete_id": "uci-9", "label": "Team Time Trial", "result_date": "2026-07-04", "points": 5},
        ]
        db = FakeDb({"results": existing}).install()
        rr.save_points("tour/2026", self.EVENTS, [
            self.row(1, "uci-1", 60),
            self.row(1, "uci-2", 0, rank=30),       # ohne Punkte
            self.row(1, None, 40, rank=2),          # nicht zugeordneter Fahrer
            self.row(2, "uci-3", 5),                # gleicher Name von Etappe und Wertung → nur einmal im Label
            self.row(3, "uci-4", 30),               # Wertung ohne Datum
        ])
        sel, = db.of("select", "results")
        self.assertEqual(sel[2]["result_date"], "gte.2026-07-04")
        # aberkannt: uci-9 fällt weg, die Mannschaftswertung bleibt stehen (kommt aus dem Ranking-Abgleich)
        self.assertEqual(db.of("delete", "results"), [("delete", "results", {"id": "in.(11)"})])
        (_, _, rows, key), = db.of("upsert", "results")
        self.assertEqual(key, "athlete_id,competition_id,label")
        self.assertEqual(sorted((r["athlete_id"], r["label"], r["points"]) for r in rows), [
            ("uci-1", "Stage 1 · Stage Classification", 60.0),
            ("uci-3", "Stage 1", 5.0),
        ])
        self.assertFalse(db.of("insert"), "Push „Neue Punkte“ kommt nur aus der Datenbank, nicht doppelt von hier")

    def test_ohne_datum_nichts_tun(self):
        db = FakeDb().install()
        rr.save_points("x/2026", [self.EVENTS[2]], [self.row(3, "uci-1", 10)])
        self.assertEqual(db.calls, [])


class ReplaceProvisional(unittest.TestCase):
    def test_ersetzt_und_abgelaufen(self):
        db = FakeDb({"competitions": [
            {"id": "a/2027", "category": "1.UWT", "start_date": "2027-04-11", "end_date": None},   # DataRide hat es
            {"id": "b/2026", "category": "1.1", "start_date": "2026-11-01", "end_date": "2026-11-02"},  # abgelaufen
            {"id": "c/2027", "category": "1.1", "start_date": "2027-05-01", "end_date": "2027-05-01"},  # bleibt
        ]}).install()
        rr.replace_provisional("men", [{"category": "1.UWT", "start_date": "2027-04-13"}], TODAY)
        self.assertEqual([c[2]["id"] for c in db.of("delete", "competitions")], ["eq.a/2027", "eq.b/2026"])


class RemoveUnlisted(unittest.TestCase):
    def test_nur_ungeladene_ohne_dataride_eintrag(self):
        db = FakeDb({"competitions": [{"id": "u23/2026", "dataride_id": 5}, {"id": "ok/2026", "dataride_id": 6}]}).install()
        rr.remove_unlisted("men", {6}, 2026)
        self.assertEqual(db.of("delete", "competitions"), [("delete", "competitions", {"id": "eq.u23/2026", "loaded_at": "is.null"})])
        self.assertEqual(db.of("select", "competitions")[0][2]["loaded_at"], "is.null")


class SetSeasons(unittest.TestCase):
    def test_in_paketen_je_saison(self):
        db = FakeDb().install()
        comps = [{"CompetitionId": i, "_season": 2026} for i in range(200)] + [{"CompetitionId": 999, "_season": 2027}]
        rr.set_seasons("women", comps)
        ups = db.of("update", "competitions")
        self.assertEqual([(len(u[2]["dataride_id"].split(",")), u[3]) for u in ups],
                         [(150, {"season": 2026}), (50, {"season": 2026}), (1, {"season": 2027})])


if __name__ == "__main__":
    unittest.main()
