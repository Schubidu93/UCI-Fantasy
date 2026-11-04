"""
Einmaliger Test: Welche Datenquelle ist von GitHub aus normal erreichbar?
Ruft jede Seite einmal mit ehrlicher Kennung auf (kein vorgetäuschter Browser)
und protokolliert Status, Titel, Bot-Sperre und robots.txt.
"""
import re
import time
import requests

UA = "UCI-Fantasy-Probe/0.1 (private Fantasy-Liga; https://github.com/Schubidu93/UCI-Fantasy)"
URLS = [
    "https://dataride.uci.ch/robots.txt",
    "https://dataride.uci.ch/iframe/Rankings/7/",
    "https://www.uci.org/robots.txt",
    "https://firstcycling.com/robots.txt",
    "https://firstcycling.com/ranking.php?rank=1&y=2026&k=uci",
    "https://firstcycling.com/rider.php?r=45992&y=2026",
    "https://www.procyclingstats.com/robots.txt",
]


def show(url):
    try:
        r = requests.get(url, headers={"User-Agent": UA}, timeout=30)
    except Exception as e:
        print(f"\n### {url}\nFEHLER: {e}")
        return None
    body = r.text
    title = re.search(r"<title[^>]*>(.*?)</title>", body, re.S | re.I)
    blocked = bool(re.search(r"Just a moment|Attention Required|cf-challenge|captcha", body, re.I))
    print(f"\n### {url}\nHTTP {r.status_code} · {len(body)} Zeichen · Titel: {title.group(1).strip()[:80] if title else '-'}"
          f" · Bot-Sperre: {'JA' if blocked else 'nein'} · Server: {r.headers.get('server')}")
    if url.endswith("robots.txt"):
        print(body[:1500])
    return body


for u in URLS:
    body = show(u)
    if body and "dataride" in u and "Rankings" in u:
        # Welche Datenschnittstellen ruft die Seite auf?
        apis = sorted(set(re.findall(r"""["'](/iframe/[A-Za-z]+[^"'\s]*)["']""", body)))
        print("Gefundene Endpunkte:", apis[:40])
        scripts = re.findall(r"""<script[^>]+src=["']([^"']+)""", body)
        print("Skripte:", scripts[:20])
        for s in scripts:
            if s.startswith("/") and "jquery" not in s.lower():
                time.sleep(1)
                js = requests.get("https://dataride.uci.ch" + s, headers={"User-Agent": UA}, timeout=30).text
                found = sorted(set(re.findall(r"""["'](/iframe/[A-Za-z]+/?[A-Za-z]*)["']""", js)))
                if found:
                    print(f"  {s}: {found[:40]}")
        inline = re.findall(r"url\s*:\s*['\"]([^'\"]+)['\"]", body)
        print("Inline-URLs:", sorted(set(inline))[:40])
        print("Ausschnitt Formular/Parameter:", re.findall(r'(?:data-[a-z-]+|name)="[^"]{0,40}"', body)[:60])
    time.sleep(2)
