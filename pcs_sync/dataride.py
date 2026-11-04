"""
Zugriff auf UCI DataRide (dataride.uci.ch) – die offizielle Quelle des UCI-Weltrankings.

Die Website lädt ihre Tabellen über dieselben Abfragen, die hier verwendet werden:
  1. GetDisciplineSeasons      → Saison-ID (Straße = Disziplin 10)
  2. RankingsDiscipline        → die UCI-Weltrangliste der Kategorie (Männer/Frauen Elite)
  3. ObjectRankings            → Fahrer der Rangliste mit Rang, Team, Nation, Punkten
  4. IndividualEventRankings   → pro Fahrer jedes Ergebnis mit UCI-Punkten und Datum

Abrufe bewusst sparsam und mit ehrlicher Kennung (keine Browser-Tarnung).
"""
import re
import time
import unicodedata
from datetime import date, datetime

import requests

BASE = "https://dataride.uci.ch"
USER_AGENT = "UCI-Fantasy/1.0 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
ROAD = 10                                   # Disziplin Straße
CATEGORY = {"men": 22, "women": 23}         # Men Elite / Women Elite
PAUSE = 1.0                                 # Sekunden zwischen Abfragen


class DataRide:
    def __init__(self, pause=PAUSE):
        self.pause = pause
        self.s = requests.Session()
        self.s.headers.update({"User-Agent": USER_AGENT, "X-Requested-With": "XMLHttpRequest"})

    def _call(self, method, path, data):
        for attempt in range(3):
            time.sleep(self.pause)
            try:
                r = self.s.request(method, BASE + path, timeout=60,
                                   params=data if method == "GET" else None,
                                   data=data if method == "POST" else None)
                r.raise_for_status()
                return r.json()
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"DataRide {path}: {e}") from e
                time.sleep(5 * (attempt + 1))

    # ---- Saison und Rangliste --------------------------------------------

    def season(self, year=None):
        """Saison-Eintrag der Straße für das Jahr (Standard: aktuelles Jahr, sonst die neueste)."""
        year = year or date.today().year
        seasons = self._call("GET", "/iframe/GetDisciplineSeasons/", {"disciplineId": ROAD}) or []
        match = [x for x in seasons if x.get("Year") == year]
        return match[0] if match else max(seasons, key=lambda x: x.get("Year", 0))

    def _filters(self, gender, season_id, moment_id=None):
        f = {"filter[logic]": "and",
             "filter[filters][0][field]": "RaceTypeId", "filter[filters][0][value]": 0,
             "filter[filters][1][field]": "CategoryId", "filter[filters][1][value]": CATEGORY[gender],
             "filter[filters][2][field]": "SeasonId", "filter[filters][2][value]": season_id}
        if moment_id is not None:
            f.update({"filter[filters][3][field]": "MomentId", "filter[filters][3][value]": moment_id})
        return f

    def world_ranking(self, gender, season_id):
        """Die Einzel-Weltrangliste (RankingTypeId 1) der Kategorie."""
        data = {"disciplineId": ROAD, "take": 100, "skip": 0, "page": 1, "pageSize": 100,
                **self._filters(gender, season_id)}
        for group in self._call("POST", "/iframe/RankingsDiscipline/", data) or []:
            for rk in group.get("Rankings") or []:
                if rk.get("RankingTypeId") == 1 and rk.get("RankingName", "").strip() == "UCI World Ranking":
                    return rk
        raise RuntimeError(f"UCI-Weltrangliste ({gender}) nicht gefunden")

    def ranking_riders(self, rk, gender, season_id, limit=1000, page_size=200):
        """Fahrer der Rangliste, nach Rang sortiert."""
        out = []
        while len(out) < limit:
            data = {"rankingId": rk["Id"], "disciplineId": ROAD, "rankingTypeId": rk["RankingTypeId"],
                    "take": page_size, "skip": len(out), "page": len(out) // page_size + 1, "pageSize": page_size,
                    **self._filters(gender, season_id, rk["MomentId"])}
            rows = (self._call("POST", "/iframe/ObjectRankings/", data) or {}).get("data") or []
            out += rows
            if len(rows) < page_size:
                break
        return out[:limit]

    def rider_results(self, rk, gender, season_id, object_id):
        """Alle Ergebnisse eines Fahrers, die in der Weltrangliste Punkte bringen."""
        data = {"individualId": object_id, "rankingId": rk["Id"], "momentId": rk["MomentId"],
                "groupId": rk["GroupId"], "baseRankingTypeId": rk["RankingTypeId"],
                "disciplineSeasonId": season_id, "disciplineId": ROAD, "categoryId": CATEGORY[gender],
                "raceTypeId": 0, "countryId": 0, "teamId": 0,
                "take": 1000, "skip": 0, "page": 1, "pageSize": 1000}
        return (self._call("POST", "/iframe/IndividualEventRankings/", data) or {}).get("data") or []


# ---- Umwandlung in unsere Tabellen --------------------------------------------

def rider_slug(object_id):
    """Stabile Fahrer-ID in unserer Datenbank (Spalte pcs_slug)."""
    return f"uci-{object_id}"


def object_id(slug):
    return int(slug.split("-", 1)[1])


def slugify(text):
    t = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def parse_date(row):
    """'28 Aug 2026' bzw. '/Date(1787868000000)/' → date"""
    try:
        return datetime.strptime(row.get("Date", ""), "%d %b %Y").date()
    except ValueError:
        m = re.search(r"(\d{10,})", row.get("StartDate") or "")
        if not m:
            return None
        # DataRide liefert Mitternacht Schweizer Zeit; +12 h landet sicher auf dem richtigen Tag
        return datetime.utcfromtimestamp(int(m.group(1)) / 1000 + 12 * 3600).date()


def result_row(row):
    """Ein DataRide-Ergebnis → (race, result) für unsere Tabellen; None wenn es nicht zählt."""
    points = float(row.get("Points") or 0)
    day = parse_date(row)
    if row.get("IsInvalidResult") or points <= 0 or not day:
        return None
    comp = (row.get("CompetitionName") or "Unbekanntes Rennen").strip()
    race_slug = f"{slugify(comp)}/{day.year}"
    parts = [p.strip() for p in (row.get("RaceName"), row.get("EventName")) if p and p.strip()]
    label = " · ".join(dict.fromkeys(parts)) or "Ergebnis"
    return (
        {"pcs_slug": race_slug, "name": comp, "uci_class": row.get("ClassCode"), "date": day},
        {"race_slug": race_slug, "label": label[:200], "result_date": day.isoformat(),
         "rank": row.get("Rank") if isinstance(row.get("Rank"), int) else None, "uci_points": points},
    )
