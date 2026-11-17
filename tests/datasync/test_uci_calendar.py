"""Künftige Rennen aus dem UCI-Wettkampfverzeichnis (vorläufige Kalendereinträge)."""
import unittest
from datetime import date

from helpers import FakeDb
import uci_calendar
from uci_calendar import genders, provisional_rows

TODAY = date(2026, 11, 17)


def item(name, cls, start, end=None, cats=None, country="FRA"):
    return {"name": name, "classCode": cls, "startDate": start, "endDate": end, "categoryCodes": cats or [],
            "countryCode": country, "seasonYear": int(start[:4]) if start else None}


class Genders(unittest.TestCase):
    def test_aus_kategorien(self):
        self.assertEqual(genders(item("X", "1.1", "2027-03-01", cats=["ME", "WE", "MU"])), ["men", "women"])
        self.assertEqual(genders(item("X", "1.1", "2027-03-01", cats=["WE"])), ["women"])

    def test_meisterschaften_beide(self):
        self.assertEqual(genders(item("Championnats", "CM", "2027-09-20")), ["men", "women"])
        self.assertEqual(genders(item("Continental", "CC", "2027-06-20")), ["men", "women"])

    def test_frauen_aus_klasse_oder_name(self):
        self.assertEqual(genders(item("Tour", "2.WWT", "2027-05-01")), ["women"])
        self.assertEqual(genders(item("Tour de France Femmes", "2.1", "2027-07-25")), ["women"])
        self.assertEqual(genders(item("Giro d'Italia Donne", "2.1", "2027-07-05")), ["women"])
        self.assertEqual(genders(item("Paris-Roubaix", "1.UWT", "2027-04-11")), ["men"])


class ProvisionalRows(unittest.TestCase):
    def test_filter(self):
        items = [
            item("Paris-Roubaix", "1.UWT", "2027-04-11"),
            item("Paris-Roubaix", "1.UWT", "2027-04-11"),                 # doppelt → einmal
            item("Tour Nachwuchs", "2.2U", "2027-05-01"),                 # Klasse nicht geführt
            item("Gestern", "1.1", "2026-11-17"),                         # nicht in der Zukunft
            item("Ohne Datum", "1.1", None),
            item("Schon bei DataRide", "1.Pro", "2027-02-02"),           # DataRide ±3 Tage, gleiche Klasse
            item("Andere Klasse", "1.1", "2027-02-03"),                   # gleiche Zeit, andere Klasse → bleibt
            item("Belegt", "1.2", "2027-03-03"),                          # ID schon von DataRide vergeben
            item("Frauenrennen", "1.WWT", "2027-04-12"),                  # andere Wertung
        ]
        dataride_cal = [{"uci_class": "1.Pro", "start_date": "2027-02-05"}]
        rows = provisional_rows(items, "men", dataride_cal,
                                {"belegt/2027"}, TODAY)
        self.assertEqual(sorted(r["pcs_slug"] for r in rows), ["andere-klasse/2027", "paris-roubaix/2027"])
        pr = next(r for r in rows if r["pcs_slug"] == "paris-roubaix/2027")
        self.assertEqual(pr, {"pcs_slug": "paris-roubaix/2027", "name": "Paris-Roubaix", "gender": "men",
                              "uci_class": "1.UWT", "country": "FRA", "start_date": "2027-04-11",
                              "end_date": "2027-04-11", "season": 2027, "provisional": True})

    def test_frauen_eigene_id(self):
        rows = provisional_rows([item("Paris-Roubaix Femmes", "1.WWT", "2027-04-10")], "women", [], set(), TODAY)
        self.assertEqual(rows[0]["pcs_slug"], "paris-roubaix-femmes/2027/w")


class Sync(unittest.TestCase):
    def test_vorlaeufige_neu_setzen(self):
        db = FakeDb({"races": [{"pcs_slug": "belegt/2027"}]}).install()
        uci_calendar.sync("men", [], TODAY, [item("Belegt", "1.2", "2027-03-03"), item("Neu", "1.2", "2027-03-04")])
        self.assertEqual(db.of("delete", "races"), [("delete", "races", {"gender": "eq.men", "provisional": "is.true"})])
        (_, _, rows, key), = db.of("upsert", "races")
        self.assertEqual(([r["pcs_slug"] for r in rows], key), (["neu/2027"], "pcs_slug"))


if __name__ == "__main__":
    unittest.main()
