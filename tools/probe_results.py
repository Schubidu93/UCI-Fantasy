"""Einmaliger Test: Ergebnis-Abfragen (Competitions → Races → Events → Results) bei UCI DataRide."""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})


def call(path, data):
    time.sleep(1)
    r = s.post(BASE + path, data=data, timeout=60)
    print(f"\n### POST {path} {json.dumps(data)[:300]}\nHTTP {r.status_code} · {len(r.text)} Zeichen")
    try:
        j = r.json()
    except Exception:
        print(r.text[:300]); return None
    rows = j.get("data") if isinstance(j, dict) else j
    if isinstance(j, dict) and "total" in j:
        print("total:", j["total"])
    for x in (rows or [])[:3]:
        print(json.dumps(x, ensure_ascii=False)[:1500])
    return rows


page = s.get(BASE + "/iframe/Rankings/10/", timeout=30).text
for key in ["/iframe/Competitions/", "/iframe/Races/"]:
    i = page.find(key)
    print(f"\n===== {key} =====\n" + page[max(0, i - 1500): i + 200])
for name in ["createIframeCompetitionGri", "competitionsSource", "racesSource"]:
    i = page.find(name)
    if i >= 0:
        print(f"\n===== {name} =====\n" + page[i: i + 1500])

# Versuch mit typischen Kendo-Parametern
comps = call("/iframe/Competitions/", {"disciplineId": 10, "take": 5, "skip": 0, "page": 1, "pageSize": 5,
             "filter[logic]": "and",
             "filter[filters][0][field]": "SeasonId", "filter[filters][0][value]": 464,
             "filter[filters][1][field]": "RaceTypeId", "filter[filters][1][value]": 0,
             "filter[filters][2][field]": "CategoryId", "filter[filters][2][value]": 22})
if comps:
    c = comps[0]
    races = call("/iframe/Races/", {"disciplineId": 10, "competitionId": c.get("Id")})
    if races:
        evs = call("/iframe/Events/", {"disciplineId": 10, "raceId": races[0].get("Id")})
        if evs:
            call("/iframe/Results/", {"disciplineId": 10, "eventId": evs[0].get("Id"), "take": 5, "skip": 0, "page": 1, "pageSize": 5})
