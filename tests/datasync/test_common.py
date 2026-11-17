"""Gemeinsame Python-Skripte beider Apps: Supabase-Zugang (db.py), Push-Versand (send_push.py), Feedback-Mail (send_feedback.py)."""
import importlib
import os
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

from helpers import FakeDb
from app_info import APP_NAME


def load_db(key, url="https://abc.supabase.co/rest/v1/"):
    with mock.patch.dict(os.environ, {"SUPABASE_URL": url, "SUPABASE_SERVICE_KEY": key}):
        sys.modules.pop("db", None)
        return importlib.import_module("db")


class Db(unittest.TestCase):
    def tearDown(self):
        sys.modules.pop("db", None)

    def test_neuer_schluessel_nur_apikey(self):
        db = load_db(" sb_secret_abc \n")
        self.assertEqual(db.URL, "https://abc.supabase.co")
        self.assertEqual(db.HEADERS, {"apikey": "sb_secret_abc", "Content-Type": "application/json"})

    def test_alter_schluessel_auch_bearer(self):
        db = load_db("eyJhbGciOi", url="https://abc.supabase.co")
        self.assertEqual(db.HEADERS["Authorization"], "Bearer eyJhbGciOi")


def push_stubs():
    """send_push braucht pywebpush/py_vapid/cryptography – für den Test genügen Platzhalter (webpush wird ersetzt)."""
    class WebPushException(Exception):
        def __init__(self, msg, response=None):
            super().__init__(msg)
            self.response = response
    mods = {"pywebpush": types.SimpleNamespace(WebPushException=WebPushException, webpush=None),
            "py_vapid": types.SimpleNamespace(Vapid=None),
            "cryptography": types.ModuleType("cryptography"),
            "cryptography.hazmat": types.ModuleType("cryptography.hazmat"),
            "cryptography.hazmat.primitives": types.SimpleNamespace(serialization=None)}
    return mock.patch.dict(sys.modules, mods)


class SendPush(unittest.TestCase):
    def run_push(self, pending, subs, fail=None):
        now = datetime.now(timezone.utc)
        for n in pending:
            n.setdefault("created_at", now.isoformat())
        db = FakeDb({"notifications": pending, "push_subscriptions": subs})
        sent = []
        with push_stubs():
            sys.modules["db"] = db
            sys.modules.pop("send_push", None)
            sp = importlib.import_module("send_push")

            def webpush(subscription_info, data, **kw):
                if fail and subscription_info["endpoint"] in fail:
                    raise sp.WebPushException("weg", response=types.SimpleNamespace(status_code=fail[subscription_info["endpoint"]]))
                sent.append((subscription_info["endpoint"], data))
            with mock.patch.object(sp, "ensure_vapid", return_value="v"), mock.patch.object(sp, "webpush", webpush), \
                    mock.patch("builtins.print"):
                sp.main()
            sys.modules.pop("send_push", None)
        return db, sent

    def test_versand_und_aufraeumen(self):
        old = (datetime.now(timezone.utc) - timedelta(days=4)).isoformat()
        pending = [
            {"id": 1, "user_id": "u1", "title": "Hallo", "body": None, "url": "#/x"},
            {"id": 2, "user_id": "u1", "title": "Abgelaufen", "expires_at": "2020-01-01T00:00:00Z"},
            {"id": 3, "user_id": "u2", "title": "Ohne Abo"},
            {"id": 4, "user_id": "u3", "title": "Fehlgeschlagen, neu"},
            {"id": 5, "user_id": "u3", "title": "Fehlgeschlagen, alt", "created_at": old},
        ]
        subs = [{"user_id": "u1", "endpoint": "e1", "p256dh": "k", "auth": "a"},
                {"user_id": "u1", "endpoint": "e-weg", "p256dh": "k", "auth": "a"},
                {"user_id": "u3", "endpoint": "e3", "p256dh": "k", "auth": "a"}]
        db, sent = self.run_push(pending, subs, fail={"e-weg": 410, "e3": 500})
        self.assertEqual(sent, [("e1", '{"title": "Hallo", "body": "", "url": "#/x"}')])
        (_, _, filters, values), = db.of("update", "notifications")
        self.assertEqual(filters, {"id": "in.(1,2,3,5)"}, "Nr. 4 wird beim nächsten Lauf erneut versucht")
        self.assertIn("sent_at", values)
        self.assertEqual(db.of("delete", "push_subscriptions"),
                         [("delete", "push_subscriptions", {"endpoint": "eq.e-weg"})])

    def test_nichts_offen(self):
        db, sent = self.run_push([], [])
        self.assertEqual((sent, db.of("update")), ([], []))


class SendFeedback(unittest.TestCase):
    def test_mail_mit_bild(self):
        sys.modules["db"] = FakeDb()
        sys.modules.pop("send_feedback", None)
        sf = importlib.import_module("send_feedback")
        msg = sf.build({"team_name": "Team A", "user_email": "a@example.org", "message": "Super App",
                        "league_name": "Liga", "page": "#/x", "device": "iPhone", "created_at": "2026-11-17T10:00:00Z"},
                       [{"mime": "image/jpeg", "data": "\\x" + b"JPG".hex()}])
        self.assertEqual(msg["Subject"], f"{APP_NAME} Feedback von Team A")
        self.assertEqual(msg["Reply-To"], "a@example.org")
        att, = list(msg.iter_attachments())
        self.assertEqual((att.get_filename(), att.get_content()), ("bild-1.jpg", b"JPG"))
        self.assertIn("Super App", msg.get_body().get_content())
        with self.assertRaises(ValueError):
            sf.to_bytes(b"roh")


if __name__ == "__main__":
    unittest.main()
