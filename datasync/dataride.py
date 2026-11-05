"""
Zugriff auf UCI DataRide (dataride.uci.ch) – die offizielle Quelle des UCI-Weltrankings.

Die Website lädt ihre Tabellen über dieselben Abfragen, die hier verwendet werden:
  Fahrer:   GetDisciplineSeasons → RankingsDiscipline → ObjectRankings (Rang, Team, Nation, Geburtsdatum)
  Rennen:   Competitions → Races (Etappen) → Events (Wertungen) → Results (Rang, Zeit, UCI-Punkte)

Abrufe bewusst sparsam und mit ehrlicher Kennung (keine Browser-Tarnung).
"""
import re
import time
import unicodedata
from datetime import date, datetime, timedelta

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


    # ---- Rennkalender und Ergebnislisten -------------------------------

    def competitions(self, gender, season_id, page_size=100):
        """Alle Rennen der Saison (Straße, Elite) – neueste zuerst."""
        out = []
        while True:
            data = {"disciplineId": ROAD, "take": page_size, "skip": len(out), "page": len(out) // page_size + 1,
                    "pageSize": page_size, "sort[0][field]": "StartDate", "sort[0][dir]": "desc",
                    **self._filters(gender, season_id)}
            rows = (self._call("POST", "/iframe/Competitions/", data) or {}).get("data") or []
            out += rows
            if len(rows) < page_size:
                return out

    def races(self, competition_id):
        """Etappen bzw. Renntage eines Rennens."""
        data = {"disciplineId": ROAD, "competitionId": competition_id, "take": 100, "skip": 0, "page": 1, "pageSize": 100}
        return (self._call("POST", "/iframe/Races/", data) or {}).get("data") or []

    def events(self, race_id):
        """Wertungen einer Etappe (Etappe, Gesamt, Punkte, Berg, Nachwuchs …)."""
        return self._call("POST", "/iframe/Events/", {"disciplineId": ROAD, "raceId": race_id}) or []

    def results(self, event_id, keep_top=25, page_size=100):
        """Ergebnisliste: Top `keep_top` plus alle weiteren Plätze mit UCI-Punkten."""
        out = []
        while True:
            data = {"disciplineId": ROAD, "eventId": event_id, "take": page_size, "skip": len(out),
                    "page": len(out) // page_size + 1, "pageSize": page_size}
            rows = (self._call("POST", "/iframe/Results/", data) or {}).get("data") or []
            out += rows
            beyond = [r for r in rows if (r.get("SortOrder") or 0) > keep_top]
            if len(rows) < page_size or (beyond and not any((r.get("PointPcR") or 0) > 0 for r in beyond)):
                break
        return [r for r in out if (r.get("SortOrder") or 0) <= keep_top or (r.get("PointPcR") or 0) > 0]


def ms_date(value):
    """'/Date(1787868000000)/' → date (DataRide: Mitternacht Schweizer Zeit)"""
    m = re.search(r"(-?\d{9,})", value or "")
    if not m or int(m.group(1)) <= -62135596800000 + 86400000:   # "0001-01-01" = kein Datum
        return None
    return (datetime(1970, 1, 1) + timedelta(milliseconds=int(m.group(1)) + 12 * 3600 * 1000)).date()


# ---- Umwandlung in unsere Tabellen --------------------------------------------

def rider_slug(object_id):
    """Stabile Fahrer-ID in unserer Datenbank (Spalte pcs_slug)."""
    return f"uci-{object_id}"


def slugify(text):
    t = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", t).strip("-")


def race_slug(competition_name, year, gender):
    """Stabile Rennen-ID; Frauenrennen bekommen '/w', weil z. B. die WM gleich heißt."""
    return f"{slugify(competition_name)}/{year}" + ("/w" if gender == "women" else "")


def normalize_name(name):
    """'POGAČAR Tadej' und 'Pogacar  Tadej' → 'pogacar tadej' (Wortreihenfolge egal)."""
    t = unicodedata.normalize("NFKD", name or "").encode("ascii", "ignore").decode().lower()
    return " ".join(sorted(re.findall(r"[a-z0-9]+", t)))
