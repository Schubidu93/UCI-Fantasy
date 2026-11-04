"""
Einmaliger Test (Teil 3): Liefert UCI DataRide die Ergebnisse pro Fahrer mit Punkten?
Drei Abfragen wie die Seite selbst: Ranglisten → Fahrer → Ergebnisse eines Fahrers.
"""
import json
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})
s.get(BASE + "/iframe/Rankings/7/", timeout=30)


def post(path, data):
    time.sleep(1.5)
    r = s.post(BASE + path, data=data, timeout=30)
    print(f"\n### POST {path} {data}\nHTTP {r.status_code} · {r.headers.get('content-type')} · {len(r.text)} Zeichen")
    try:
        return r.json()
    except Exception:
        print(r.text[:500])
        return None


def show(obj, n=3):
    if isinstance(obj, dict) and "data" in obj:
        print("total:", obj.get("total"))
        obj = obj["data"]
    if isinstance(obj, list):
        for x in obj[:n]:
            print(json.dumps(x, ensure_ascii=False)[:1500])
    else:
        print(json.dumps(obj, ensure_ascii=False)[:1500])
    return obj


seasons = s.get(BASE + "/iframe/GetDisciplineSeasons/", params={"disciplineId": 7}, timeout=30).json()
print("Saisons:", json.dumps(seasons, ensure_ascii=False)[:800])

rd = show(post("/iframe/RankingsDiscipline/", {"disciplineId": 7, "take": 40, "skip": 0, "page": 1, "pageSize": 40}), 6)

# erste Rangliste mit Fahrern (Einzel, Männer Elite) suchen
cand = None
for grp in (rd or []):
    for rk in (grp.get("Rankings") or [grp]):
        name = json.dumps(rk, ensure_ascii=False)
        if "Individual" in name and ("Men Elite" in name or "ME" in name):
            cand = rk
            break
    if cand:
        break
print("\nGewählte Rangliste:", json.dumps(cand, ensure_ascii=False)[:600])

if cand:
    rid = cand.get("Id") or cand.get("RankingId")
    data = {"rankingId": rid, "disciplineId": 7, "rankingTypeId": cand.get("RankingTypeId", 1),
            "take": 5, "skip": 0, "page": 1, "pageSize": 5}
    objs = show(post("/iframe/ObjectRankings/", data), 3)
    if objs:
        o = objs[0]
        rr = {"objectId": o.get("ObjectId"), "groupId": cand.get("GroupId"), "momentId": o.get("MomentId") or cand.get("MomentId"),
              "rankingId": rid, "rankingTypeId": cand.get("RankingTypeId", 1), "disciplineSeasonId": o.get("DisciplineSeasonId"),
              "disciplineId": 7, "categoryId": cand.get("CategoryId"), "raceTypeId": cand.get("RaceTypeId"),
              "take": 40, "skip": 0, "page": 1, "pageSize": 40}
        print("\nAlle Felder des ersten Fahrers:", json.dumps(o, ensure_ascii=False))
        show(post("/iframe/RidersResults/", rr), 8)
