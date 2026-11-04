"""
Einmaliger Test (Teil 2): Wie ruft die UCI-DataRide-Seite ihre Daten ab?
Gibt den JavaScript-Kontext um die Endpunkte aus und probiert die
Ranglisten-Abfrage so, wie die Seite sie selbst stellt.
"""
import json
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
BASE = "https://dataride.uci.ch"
s = requests.Session()
s.headers["User-Agent"] = UA

page = s.get(BASE + "/iframe/Rankings/7/", timeout=30).text
for key in ["ObjectRankings", "RidersResults", "IndividualEventRankings", "RankingsDiscipline", "GetDisciplineSeasons", "Results/"]:
    for m in list(re.finditer(re.escape("/iframe/" + key), page))[:2]:
        print(f"\n===== {key} @ {m.start()} =====")
        print(page[max(0, m.start() - 900): m.start() + 900])

# Formular-/Datenattribute der Seite
print("\n===== data-* Attribute =====")
print(sorted(set(re.findall(r'data-[a-z-]+="[^"]{0,60}"', page)))[:80])
print("\n===== Hidden inputs =====")
print(re.findall(r'<input[^>]+type="hidden"[^>]*>', page)[:20])
