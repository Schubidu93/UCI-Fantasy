"""Einmaliger Test: richtige Parameter für /iframe/Competitions/ finden."""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})

page = s.get(BASE + "/iframe/Rankings/10/", timeout=30).text
i = page.find("var iframeCompetitionsSource")
print(page[i:i + 2500])
for path in ["/iframe/Results/10/", "/iframe/Competitions/10/", "/iframe/results/10", "/iframe/Calendar/10"]:
    time.sleep(1)
    r = s.get(BASE + path, timeout=30)
    print(f"\n### GET {path}: HTTP {r.status_code} · {len(r.text)} Zeichen")
    if r.status_code == 200 and len(r.text) > 5000:
        t = r.text
        for key in ["iframeCompetitionsSource(", "filter({", "filters:", "kendoDropDownList(", "GetCompetition"]:
            for m in list(re.finditer(re.escape(key), t))[:3]:
                print(f"--- {key} @ {m.start()}\n" + t[max(0, m.start() - 400): m.start() + 900])
