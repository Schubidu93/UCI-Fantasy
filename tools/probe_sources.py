"""Einmaliger Test (Teil 4): Wie filtert die DataRide-Seite die Ranglisten?"""
import re
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
page = requests.get("https://dataride.uci.ch/iframe/Rankings/7/", headers={"User-Agent": UA}, timeout=30).text
i = page.find("var filterRankingsDiscipline")
print(page[i:i + 9000])
