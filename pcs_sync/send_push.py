"""
Push-Benachrichtigungen aus der Tabelle notifications verschicken (Web Push).

Beim ersten Lauf wird ein VAPID-Schlüsselpaar erzeugt und in app_config abgelegt
(nur mit dem Service-Key lesbar). Die App holt sich den öffentlichen Schlüssel
über die Funktion vapid_public_key().

Abgelaufene Abos (HTTP 404/410) werden gelöscht. Nachrichten, die älter als
3 Tage sind und nicht zugestellt werden konnten, werden verworfen.
"""
import base64
import json
import os
from datetime import datetime, timedelta, timezone

from cryptography.hazmat.primitives import serialization
from py_vapid import Vapid
from pywebpush import WebPushException, webpush

import db

CONTACT = "https://schubidu93.github.io"   # VAPID verlangt eine https-Adresse ohne Pfad (oder mailto:)


def ensure_vapid():
    rows = db.select("app_config", {"select": "key,value", "key": "in.(vapid_private,vapid_public)"})
    conf = {r["key"]: r["value"] for r in rows}
    if "vapid_private" in conf and "vapid_public" in conf:
        return Vapid.from_pem(conf["vapid_private"].encode())
    v = Vapid()
    v.generate_keys()
    pem = v.private_pem().decode()
    raw = v.public_key.public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    public = base64.urlsafe_b64encode(raw).decode().rstrip("=")
    db.upsert("app_config", [{"key": "vapid_private", "value": pem}, {"key": "vapid_public", "value": public}], "key")
    print("Neues VAPID-Schlüsselpaar erzeugt.")
    return v


def queue_test():
    """Testnachricht an alle Nutzer mit eingeschalteten Benachrichtigungen vormerken."""
    users = sorted({s["user_id"] for s in db.select("push_subscriptions", {"select": "user_id"})})
    if users:
        db.insert("notifications", [{"user_id": u, "title": "🚴 Test von UCI Fantasy",
                                     "body": "Benachrichtigungen funktionieren! Antippen öffnet die App.", "url": ""} for u in users])
    print(f"Testnachricht für {len(users)} Nutzer vorgemerkt.")


def main():
    vapid = ensure_vapid()
    if os.environ.get("TEST") == "1":
        queue_test()
    pending = db.select("notifications", {"select": "*", "sent_at": "is.null", "order": "id", "limit": 500})
    if not pending:
        print("Keine neuen Benachrichtigungen.")
        return
    users = sorted({n["user_id"] for n in pending})
    subs = db.select("push_subscriptions", {"select": "*", "user_id": f"in.({','.join(users)})"})
    by_user = {}
    for s in subs:
        by_user.setdefault(s["user_id"], []).append(s)

    sent, gone, done = 0, set(), []
    now = datetime.now(timezone.utc)
    for n in pending:
        expires = n.get("expires_at")
        if expires and datetime.fromisoformat(expires.replace("Z", "+00:00")) < now:
            done.append(n["id"])          # z. B. „Du bist dran“, der Pick ist längst vorbei
            continue
        payload = json.dumps({"title": n["title"], "body": n.get("body") or "", "url": n.get("url") or ""})
        delivered = False
        for s in by_user.get(n["user_id"], []):
            if s["endpoint"] in gone:
                continue
            try:
                webpush(subscription_info={"endpoint": s["endpoint"], "keys": {"p256dh": s["p256dh"], "auth": s["auth"]}},
                        data=payload, vapid_private_key=vapid, vapid_claims={"sub": CONTACT}, ttl=86400, timeout=20)
                delivered = True
                sent += 1
            except WebPushException as e:
                code = getattr(e.response, "status_code", None)
                if code in (404, 410):
                    gone.add(s["endpoint"])
                else:
                    print(f"  Fehler {code}: {str(e)[:150]}")
            except Exception as e:
                print(f"  Fehler: {str(e)[:150]}")
        created = datetime.fromisoformat(n["created_at"].replace("Z", "+00:00"))
        if delivered or not by_user.get(n["user_id"]) or now - created > timedelta(days=3):
            done.append(n["id"])

    for i in range(0, len(done), 200):
        db.update("notifications", {"id": f"in.({','.join(map(str, done[i:i + 200]))})"}, {"sent_at": now.isoformat()})
    for endpoint in gone:
        db.delete("push_subscriptions", {"endpoint": f"eq.{endpoint}"})
    print(f"{sent} Push-Nachrichten verschickt, {len(gone)} abgelaufene Abos entfernt.")


if __name__ == "__main__":
    main()
