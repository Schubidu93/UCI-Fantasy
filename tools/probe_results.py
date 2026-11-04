"""Einmaliger Test: Ergebnis-Navigation von UCI DataRide (Rennkalender → Rennen → Wertungen → Ergebnisliste)."""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})


def call(method, path, data):
    time.sleep(1)
    r = s.request(method, BASE + path, params=data if method == "GET" else None, data=data if method == "POST" else None, timeout=60)
    print(f"\n### {method} {path} {json.dumps(data)[:250]}\nHTTP {r.status_code} · {len(r.text)} Zeichen")
    try:
        return r.json()
    except Exception:
        print(r.text[:300]); return None


page = s.get(BASE + "/iframe/Calendar/10/", timeout=30).text
print("Calendar-Seite:", len(page))
for key in ["Competitions/", "Races/", "Events/", "Results/", "GetCalendarFilters", "Filter"]:
    for m in list(re.finditer(re.escape(key), page))[:1]:
        print(f"\n===== {key} =====\n" + page[max(0, m.start() - 700): m.start() + 500])
print("\nAlle iframe-URLs:", sorted(set(re.findall(r"/iframe/[A-Za-z]+/", page))))
