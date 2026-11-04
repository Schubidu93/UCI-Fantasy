"""
Einmaliger Test (Teil 5): komplette Kette bei UCI DataRide
Saison → Kategorien/Renntypen → Ranglisten → Fahrer → Ergebnisse eines Fahrers.
"""
import json
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})
s.get(BASE + "/iframe/Rankings/7/", timeout=30)


def call(method, path, data):
    time.sleep(1.5)
    r = s.request(method, BASE + path, params=data if method == "GET" else None,
                  data=data if method == "POST" else None, timeout=30)
    print(f"\n### {method} {path}\n{json.dumps(data)[:300]}\nHTTP {r.status_code} · {len(r.text)} Zeichen")
    try:
        return r.json()
    except Exception:
        print(r.text[:400]); return None


def show(obj, n=3):
    rows = obj.get("data") if isinstance(obj, dict) and "data" in obj else obj
    if isinstance(obj, dict) and "total" in obj:
        print("total:", obj["total"])
    for x in (rows if isinstance(rows, list) else [rows])[:n]:
        print(json.dumps(x, ensure_ascii=False)[:1800])
    return rows


SEASON = 453  # 2026
cats = show(call("GET", "/iframe/GetRankingsCategories/", {"disciplineId": 7, "disciplineSeasonId": SEASON}), 10)
types = show(call("GET", "/iframe/GetRankingsRaceTypes/", {"disciplineId": 7, "disciplineSeasonId": SEASON}), 10)

cat = next((c for c in cats or [] if "Men Elite" in c.get("Name", "")), (cats or [{}])[min(1, len(cats or [1]) - 1)])
rtype = next((t for t in types or [] if "Road" in t.get("Name", "")), (types or [{}])[0])
print("\nKategorie:", cat, "\nRenntyp:", rtype)

flt = {"take": 40, "skip": 0, "page": 1, "pageSize": 40, "disciplineId": 7, "filter[logic]": "and",
       "filter[filters][0][field]": "RaceTypeId", "filter[filters][0][value]": rtype.get("Id"),
       "filter[filters][1][field]": "CategoryId", "filter[filters][1][value]": cat.get("Id"),
       "filter[filters][2][field]": "SeasonId", "filter[filters][2][value]": SEASON}
rd = show(call("POST", "/iframe/RankingsDiscipline/", flt), 4)

rk = None
for grp in rd or []:
    for item in grp.get("Rankings", []) or [grp]:
        if "Individual" in json.dumps(item) and rk is None:
            rk = item
print("\nRangliste:", json.dumps(rk, ensure_ascii=False)[:1200])
if not rk:
    raise SystemExit

data = {"rankingId": rk["Id"], "disciplineId": 7, "rankingTypeId": rk.get("RankingTypeId", 1),
        "take": 3, "skip": 0, "page": 1, "pageSize": 3,
        "filter[logic]": "and", "filter[filters][0][field]": "RaceTypeId", "filter[filters][0][value]": rtype.get("Id"),
        "filter[filters][1][field]": "CategoryId", "filter[filters][1][value]": cat.get("Id"),
        "filter[filters][2][field]": "SeasonId", "filter[filters][2][value]": SEASON,
        "filter[filters][3][field]": "MomentId", "filter[filters][3][value]": rk.get("MomentId", 0)}
objs = show(call("POST", "/iframe/ObjectRankings/", data), 3)
if objs:
    o = objs[0]
    rr = {"objectId": o.get("ObjectId"), "groupId": rk.get("GroupId"), "momentId": rk.get("MomentId"),
          "rankingId": rk["Id"], "rankingTypeId": rk.get("RankingTypeId", 1), "disciplineSeasonId": SEASON,
          "disciplineId": 7, "categoryId": cat.get("Id"), "raceTypeId": rtype.get("Id"),
          "take": 40, "skip": 0, "page": 1, "pageSize": 40}
    show(call("POST", "/iframe/RidersResults/", rr), 10)
