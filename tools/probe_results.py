"""Einmaliger Test: Rennliste → Rennen → Wertungen → Ergebnisliste (mit Zeit?)."""
import json
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})
s.get(BASE + "/iframe/Results/10/", timeout=30)


def call(path, data, show=3):
    time.sleep(1)
    r = s.post(BASE + path, data=data, timeout=60)
    ok = "json" in (r.headers.get("content-type") or "")
    print(f"\n### {path} {json.dumps({k: v for k, v in data.items() if not k.startswith('sort')})[:220]}\nHTTP {r.status_code} · json={ok} · {len(r.text)} Zeichen")
    if not ok:
        return None
    j = r.json()
    rows = j.get("data") if isinstance(j, dict) else j
    if isinstance(j, dict):
        print("total:", j.get("total"))
    for x in (rows or [])[:show]:
        print(json.dumps(x, ensure_ascii=False)[:1400])
    return rows


base = {"disciplineId": 10, "take": 100, "skip": 100, "page": 2, "pageSize": 100,
        "sort[0][field]": "StartDate", "sort[0][dir]": "desc"}
def flt(rt, cat, season):
    f = {"filter[logic]": "and"}
    for i, (k, v) in enumerate([("RaceTypeId", rt), ("CategoryId", cat), ("SeasonId", season)]):
        f[f"filter[filters][{i}][field]"] = k; f[f"filter[filters][{i}][value]"] = v
    return f

comps = None
for rt, cat in [(0, 22)]:
    comps = call("/iframe/Competitions/", {**base, **flt(rt, cat, 464)})
    if comps:
        break
if not comps:
    comps = call("/iframe/Competitions/", base)
if comps:
    print("Klassen:", sorted({x["ClassCode"] for x in comps}))
    c = next((x for x in comps if x["ClassCode"] == "2.UWT"), comps[0])
    print("Gewählt:", c["CompetitionName"], c["ClassCode"], c["Date"])
    races = call("/iframe/Races/", {"disciplineId": 10, "competitionId": c["CompetitionId"], "take": 40, "skip": 0, "page": 1, "pageSize": 40}, 5)
    if races:
        rid = races[-1].get("Id") or races[-1].get("RaceId")
        evs = call("/iframe/Events/", {"disciplineId": 10, "raceId": rid}, 6)
        for ev in (evs or [])[:2]:
            eid = ev.get("Id") or ev.get("EventId")
            call("/iframe/Results/", {"disciplineId": 10, "eventId": eid, "take": 5, "skip": 0, "page": 1, "pageSize": 5}, 5)
