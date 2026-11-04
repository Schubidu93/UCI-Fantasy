"""
Einmaliger Test (Teil 6): Straße finden und Punkte pro Rennen eines Fahrers abrufen.
"""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})


def call(method, path, data):
    time.sleep(1.2)
    r = s.request(method, BASE + path, params=data if method == "GET" else None,
                  data=data if method == "POST" else None, timeout=30)
    try:
        return r.json()
    except Exception:
        return None


# Welche Disziplin-ID ist Straße? Alle durchgehen.
ROAD = SEASON = None
for d in range(1, 31):
    seas = call("GET", "/iframe/GetDisciplineSeasons/", {"disciplineId": d}) or []
    s26 = next((x for x in seas if x.get("Year") == 2026), None)
    if not s26:
        continue
    types = call("GET", "/iframe/GetRankingsRaceTypes/", {"disciplineId": d, "disciplineSeasonId": s26["Id"]}) or []
    names = [t["Name"] for t in types]
    print(d, "Saison", s26["Id"], "Renntypen:", names[:10])
    if ROAD is None and any(n in ("One day race", "Stage race", "Road race") or "Stage" in n for n in names) and "Track Race" not in names:
        ROAD, SEASON = d, s26["Id"]
print("\nStraße = Disziplin", ROAD, "Saison", SEASON)
page = s.get(f"{BASE}/iframe/Rankings/{ROAD}/", timeout=30).text
cats = call("GET", "/iframe/GetRankingsCategories/", {"disciplineId": ROAD, "disciplineSeasonId": SEASON})
print("Kategorien:", [(c["Id"], c["Name"]) for c in cats])
me = next(c for c in cats if c["Name"] == "Men Elite")
flt = {"take": 40, "skip": 0, "page": 1, "pageSize": 40, "disciplineId": ROAD, "filter[logic]": "and",
       "filter[filters][0][field]": "RaceTypeId", "filter[filters][0][value]": 0,
       "filter[filters][1][field]": "CategoryId", "filter[filters][1][value]": me["Id"],
       "filter[filters][2][field]": "SeasonId", "filter[filters][2][value]": SEASON}
groups = call("POST", "/iframe/RankingsDiscipline/", flt) or []
for g in groups:
    for rk in g.get("Rankings", []):
        print(f"  Rangliste {rk['Id']}: {rk['RankingName']} (Gruppe {rk['GroupId']}, Moment {rk['MomentId']}, Typ {rk['RankingTypeId']}, RaceType {rk['RaceTypeId']})")

rk = next(r for g in groups for r in g.get("Rankings", []) if "Individual" in r["RankingName"] or "World" in r["RankingName"])
print("\nGewählt:", rk["RankingName"])
objs = call("POST", "/iframe/ObjectRankings/", {"rankingId": rk["Id"], "disciplineId": ROAD, "rankingTypeId": rk["RankingTypeId"],
            "take": 3, "skip": 0, "page": 1, "pageSize": 3})
print("Fahrer gesamt:", objs.get("total"))
o = objs["data"][0]
print("Erster:", o["DisplayName"], o["TeamName"], o["Points"], "ObjectId", o["ObjectId"], "UciId", o["UciId"])

common = {"groupId": rk["GroupId"], "momentId": rk["MomentId"], "rankingId": rk["Id"], "disciplineSeasonId": SEASON,
          "disciplineId": ROAD, "categoryId": me["Id"], "raceTypeId": rk["RaceTypeId"],
          "take": 40, "skip": 0, "page": 1, "pageSize": 40}
ier = call("POST", "/iframe/IndividualEventRankings/", {**common, "individualId": o["ObjectId"], "baseRankingTypeId": rk["RankingTypeId"],
                                                        "countryId": 0, "teamId": 0})
print("\n### IndividualEventRankings: total", (ier or {}).get("total"))
for x in (ier or {}).get("data", [])[:12]:
    print(json.dumps(x, ensure_ascii=False)[:700])
rr = call("POST", "/iframe/RidersResults/", {**common, "objectId": o["ObjectId"], "rankingTypeId": rk["RankingTypeId"]})
print("\n### RidersResults: total", (rr or {}).get("total"))
for x in (rr or {}).get("data", [])[:5]:
    print(json.dumps(x, ensure_ascii=False)[:700])
