"""Einmaliger Test: Parameter von iframeCompetitionsSource und Aufrufstelle, dann Probeabruf."""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers.update({"User-Agent": UA, "X-Requested-With": "XMLHttpRequest"})
t = s.get(BASE + "/iframe/Results/10/", timeout=30).text
i = t.find("var iframeCompetitionsSource")
print("=== DEFINITION ===\n" + re.sub(r"\s+", " ", t[i:i + 2200]))
for m in list(re.finditer(r"iframeCompetitionsSource\(", t))[1:3]:
    print("\n=== AUFRUF ===\n" + re.sub(r"\s+", " ", t[max(0, m.start() - 1500): m.start() + 300]))
for m in list(re.finditer(r"filterCompetitions\s*=\s*function|\.filter\(\{", t))[:3]:
    print("\n=== FILTER ===\n" + re.sub(r"\s+", " ", t[m.start(): m.start() + 900]))
