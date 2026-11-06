"""
Feedback aus der App per E-Mail an den Betreiber schicken (Text + Bilder als Anhang).

Umgebung (GitHub-Secrets):
  SMTP_HOST, SMTP_PORT (Standard 465), SMTP_USER, SMTP_PASSWORD   – Postfach, über das verschickt wird
  FEEDBACK_TO                                                      – Empfänger (Standard: SMTP_USER)
  ALL=1                                                            – auch Feedback mit 3 Fehlversuchen erneut senden

Nach dem Versand werden die Bilder aus der Datenbank gelöscht (der Text bleibt).
"""
import os
import smtplib
import ssl
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formataddr

import db

HOST = os.environ.get("SMTP_HOST", "").strip()
PORT = int(os.environ.get("SMTP_PORT") or 465)
USER = os.environ.get("SMTP_USER", "").strip()
PASSWORD = os.environ.get("SMTP_PASSWORD", "")
TO = os.environ.get("FEEDBACK_TO", "").strip() or USER
ALL = os.environ.get("ALL") == "1"


def to_bytes(value):
    """bytea kommt über die REST-Schnittstelle als Hex-Text (\\x…)."""
    if isinstance(value, str) and value.startswith("\\x"):
        return bytes.fromhex(value[2:])
    raise ValueError("Unbekanntes Bildformat")


def build(fb, images):
    msg = EmailMessage()
    who = fb.get("team_name") or fb.get("user_email") or "Unbekannt"
    msg["Subject"] = f"UCI Fantasy Feedback von {who}"
    msg["From"] = formataddr(("UCI Fantasy", USER))
    msg["To"] = TO
    if fb.get("user_email"):
        msg["Reply-To"] = fb["user_email"]
    created = fb["created_at"][:16].replace("T", " ")
    lines = [
        fb.get("message") or "(kein Text)",
        "",
        "—",
        f"Von: {fb.get('user_email') or '–'}" + (f" ({fb['team_name']})" if fb.get("team_name") else ""),
        f"Liga: {fb.get('league_name') or '–'}",
        f"Seite: {fb.get('page') or '–'}",
        f"Gerät: {fb.get('device') or '–'}",
        f"Zeit (UTC): {created}",
        f"Bilder: {len(images)}",
    ]
    msg.set_content("\n".join(lines))
    for i, img in enumerate(images, 1):
        maintype, subtype = img["mime"].split("/", 1)
        ext = "jpg" if subtype == "jpeg" else subtype
        msg.add_attachment(to_bytes(img["data"]), maintype=maintype, subtype=subtype, filename=f"bild-{i}.{ext}")
    return msg


def main():
    params = {"select": "*", "sent_at": "is.null", "order": "id", "limit": 50}
    if not ALL:
        params["attempts"] = "lt.3"
    pending = db.select("feedback", params)
    print(f"{len(pending)} Feedback-Nachrichten offen")
    if not pending:
        return
    if not (HOST and USER and PASSWORD and TO):
        print("::warning::Mailzugang fehlt (Secrets SMTP_HOST, SMTP_USER, SMTP_PASSWORD) – Feedback bleibt gespeichert.")
        for fb in pending:
            db.update("feedback", {"id": f"eq.{fb['id']}"}, {"attempts": fb["attempts"] + 1})
        return
    ctx = ssl.create_default_context()
    with (smtplib.SMTP_SSL(HOST, PORT, context=ctx, timeout=60) if PORT == 465
          else smtplib.SMTP(HOST, PORT, timeout=60)) as smtp:
        if PORT != 465:
            smtp.starttls(context=ctx)
        smtp.login(USER, PASSWORD)
        for fb in pending:
            images = db.select("feedback_images", {"select": "mime,data", "feedback_id": f"eq.{fb['id']}", "order": "id"})
            try:
                smtp.send_message(build(fb, images))
            except Exception as e:
                print(f"Feedback {fb['id']}: Versand fehlgeschlagen ({e})")
                db.update("feedback", {"id": f"eq.{fb['id']}"}, {"attempts": fb["attempts"] + 1})
                continue
            db.update("feedback", {"id": f"eq.{fb['id']}"}, {"sent_at": datetime.now(timezone.utc).isoformat()})
            db.delete("feedback_images", {"feedback_id": f"eq.{fb['id']}"})
            print(f"Feedback {fb['id']} verschickt ({len(images)} Bilder)")


if __name__ == "__main__":
    main()
