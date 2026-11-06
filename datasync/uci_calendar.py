"""
Künftige Straßenrennen aus dem UCI-Wettkampfverzeichnis (uci-competition.tech.uci.ch).

Die UCI trägt Rennen in DataRide erst kurz vorher ein; im Wettkampfverzeichnis stehen sie schon
Monate früher (Name, Termin, Land, Klasse). Diese Termine werden als „vorläufig“ gespeichert
(races.provisional) und automatisch ersetzt, sobald DataRide das Rennen liefert.

Abrufe sparsam (100 Rennen je Abfrage, Pause dazwischen) und mit ehrlicher Kennung.
"""
import re
import time
from datetime import date

import requests

from dataride import USER_AGENT, race_slug

API = "https://uci-competition.tech.uci.ch/api/competitions"
PAUSE = 1.0

# Elite-Rennen, die auch DataRide führt (ohne U23, Nationencup, Junioren, nationale Meisterschaften)
CLASSES = {"1.UWT", "2.UWT", "1.WWT", "2.WWT", "1.Pro", "2.Pro", "1.1", "2.1", "1.2", "2.2", "CC", "CM"}
WOMEN_WORDS = re.compile(r"women|woman|femen|f[eé]minin|femmes|donne|dames|ladies|vrouwen|frauen|\bwe\b", re.I)


def fetch(date_from):
    """Alle Straßenrennen ab date_from (Liste der Einträge des Verzeichnisses)."""
    s = requests.Session()
    s.headers["User-Agent"] = USER_AGENT
    items, offset = [], 0
    while True:
        r = s.get(API, params={"disciplineCode": "ROA", "dateFrom": date_from.isoformat(), "sortBy": "startDate",
                               "sortOrder": "asc", "limit": 100, "offset": offset}, timeout=60)
        r.raise_for_status()
        d = r.json()
        items += d.get("items") or []
        offset += 100
        if offset >= (d.get("count") or 0) or not d.get("items"):
            return items
        time.sleep(PAUSE)


def genders(item):
    """Wertungen eines Rennens: aus den Kategorien, sonst aus Klasse bzw. Name."""
    cats = set(item.get("categoryCodes") or [])
    g = [x for x, c in (("men", "ME"), ("women", "WE")) if c in cats]
    if g:
        return g
    cls = item.get("classCode")
    if cls in ("CC", "CM"):
        return ["men", "women"]
    if cls in ("1.WWT", "2.WWT") or WOMEN_WORDS.search(item.get("name") or ""):
        return ["women"]
    return ["men"]


def provisional_rows(items, gender, dataride_cal, taken_slugs, today):
    """Kalenderzeilen für eine Wertung – ohne Rennen, die DataRide schon liefert
    (gleiche Klasse, Start höchstens 3 Tage auseinander) und ohne belegte Rennen-IDs."""
    known = [(c["uci_class"], date.fromisoformat(c["start_date"])) for c in dataride_cal]
    rows = {}
    for it in items:
        if it.get("classCode") not in CLASSES or gender not in genders(it) or not it.get("startDate"):
            continue
        start = date.fromisoformat(it["startDate"])
        if start <= today:
            continue
        if any(cls == it["classCode"] and abs((d - start).days) <= 3 for cls, d in known):
            continue
        slug = race_slug(it["name"], start.year, gender)
        if slug in taken_slugs:
            continue
        rows[slug] = {"pcs_slug": slug, "name": it["name"].strip(), "gender": gender, "uci_class": it["classCode"],
                      "country": it.get("countryCode"), "start_date": it["startDate"],
                      "end_date": it.get("endDate") or it["startDate"], "season": it.get("seasonYear"),
                      "provisional": True}
    return list(rows.values())


def sync(gender, dataride_cal, today, items):
    """Vorläufige Kalendereinträge einer Wertung neu setzen."""
    import db
    taken = {r["pcs_slug"] for r in db.select("races", {"select": "pcs_slug", "gender": f"eq.{gender}",
                                                         "provisional": "is.false",
                                                         "start_date": f"gte.{today.year}-01-01",
                                                         "limit": 5000})}
    rows = provisional_rows(items, gender, dataride_cal, taken, today)
    db.delete("races", {"gender": f"eq.{gender}", "provisional": "is.true"})
    if rows:
        db.upsert("races", rows, "pcs_slug")
    print(f"  {len(rows)} künftige Rennen aus dem UCI-Wettkampfverzeichnis (vorläufig)")
