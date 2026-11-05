"""Kleine Hilfsfunktionen für den Zugriff auf Supabase (REST-Schnittstelle)."""
import os
import re
import requests

# Projekt-Adresse ohne Zusätze – falls das Secret z. B. ".../rest/v1" enthält
URL = re.sub(r"/(rest|auth)/v1/?$", "", os.environ["SUPABASE_URL"].strip().rstrip("/"))
KEY = os.environ["SUPABASE_SERVICE_KEY"]
HEADERS = {
    "apikey": KEY,
    "Authorization": f"Bearer {KEY}",
    "Content-Type": "application/json",
}


def select(table, params):
    r = requests.get(f"{URL}/rest/v1/{table}", headers=HEADERS, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def upsert(table, rows, on_conflict):
    """Fügt Zeilen ein oder aktualisiert sie, falls schon vorhanden."""
    headers = {**HEADERS, "Prefer": "resolution=merge-duplicates,return=minimal"}
    for i in range(0, len(rows), 500):
        r = requests.post(
            f"{URL}/rest/v1/{table}",
            headers=headers,
            params={"on_conflict": on_conflict},
            json=rows[i:i + 500],
            timeout=60,
        )
        if not r.ok:
            raise RuntimeError(f"Upsert {table} fehlgeschlagen: {r.status_code} {r.text}")


def update(table, filters, values):
    headers = {**HEADERS, "Prefer": "return=minimal"}
    r = requests.patch(f"{URL}/rest/v1/{table}", headers=headers, params=filters, json=values, timeout=30)
    r.raise_for_status()


def delete(table, filters):
    headers = {**HEADERS, "Prefer": "return=minimal"}
    r = requests.delete(f"{URL}/rest/v1/{table}", headers=headers, params=filters, timeout=30)
    r.raise_for_status()


def rpc(function, args=None):
    """Ruft eine Datenbankfunktion auf (z. B. run_maintenance)."""
    r = requests.post(f"{URL}/rest/v1/rpc/{function}", headers=HEADERS, json=args or {}, timeout=120)
    if not r.ok:
        raise RuntimeError(f"RPC {function} fehlgeschlagen: {r.status_code} {r.text}")
    return r.json() if r.text else None


def insert(table, rows):
    """Neue Zeilen anlegen (ohne Konfliktbehandlung)."""
    headers = {**HEADERS, "Prefer": "return=minimal"}
    for i in range(0, len(rows), 500):
        r = requests.post(f"{URL}/rest/v1/{table}", headers=headers, json=rows[i:i + 500], timeout=60)
        if not r.ok:
            raise RuntimeError(f"Insert {table} fehlgeschlagen: {r.status_code} {r.text}")
