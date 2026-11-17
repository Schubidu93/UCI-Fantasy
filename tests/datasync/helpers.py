"""Gemeinsame Hilfen für die Tests des Datenabrufs: Pfad zu datasync/ und eine Attrappe der Datenbank (db.py)."""
import sys
import types
from pathlib import Path

DATASYNC = Path(__file__).resolve().parents[2] / "datasync"
if str(DATASYNC) not in sys.path:
    sys.path.insert(0, str(DATASYNC))


class FakeDb(types.ModuleType):
    """Ersetzt db.py: merkt sich alle Schreibzugriffe, select liefert vorbereitete Zeilen je Tabelle."""

    def __init__(self, tables=None):
        super().__init__("db")
        self.tables = tables or {}
        self.calls = []

    def select(self, table, params):
        self.calls.append(("select", table, params))
        return list(self.tables.get(table, []))

    def upsert(self, table, rows, on_conflict):
        self.calls.append(("upsert", table, rows, on_conflict))

    def insert(self, table, rows):
        self.calls.append(("insert", table, rows))

    def update(self, table, filters, values):
        self.calls.append(("update", table, filters, values))

    def delete(self, table, filters):
        self.calls.append(("delete", table, filters))

    def rpc(self, function, args=None):
        self.calls.append(("rpc", function, args))

    def of(self, kind, table=None):
        return [c for c in self.calls if c[0] == kind and (table is None or c[1] == table)]

    def install(self):
        sys.modules["db"] = self
        return self


def ms(d):
    """date → DataRide-Datum '/Date(…)/' (Mitternacht Schweizer Zeit, wie die echte Schnittstelle)."""
    from datetime import datetime, timedelta
    t = datetime(d.year, d.month, d.day) - timedelta(hours=1) - datetime(1970, 1, 1)
    return f"/Date({int(t.total_seconds() * 1000)})/"
