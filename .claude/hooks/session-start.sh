#!/bin/bash
# Bereitet eine Claude-Code-Cloud-Sitzung so vor, dass `npm test` und `npm run lint` sofort laufen:
# Node-Pakete, Python-Paket requests, PostgreSQL 16 für die Tests (Socket /tmp/fa-pg, Port 54329), Playwright-Browser.
# In beiden Apps wortgleich (scripts/shared.mjs).
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi
cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

npm install --no-audit --no-fund --silent
python3 -c "import requests" 2>/dev/null || pip install -q requests

# Vorinstallierter Browser der Umgebung für den Oberflächentest
if [ -d /opt/pw-browsers ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers' >> "$CLAUDE_ENV_FILE"
fi

# PostgreSQL 16 für die Tests: einmal anlegen, bei jedem Start sicherstellen, dass es läuft
PG=/usr/lib/postgresql/16/bin
DIR=/tmp/fa-pg
if [ -x "$PG/pg_ctl" ] && ! pg_isready -q -h "$DIR" -p 54329 2>/dev/null; then
  mkdir -p "$DIR" && chown postgres:postgres "$DIR"
  if [ ! -f "$DIR/data/PG_VERSION" ]; then
    su postgres -c "$PG/initdb -D $DIR/data -U postgres --auth=trust" > "$DIR/initdb.log"
  fi
  rm -f "$DIR/data/postmaster.pid"
  su postgres -c "$PG/pg_ctl -D $DIR/data -o '-p 54329 -k $DIR' -l $DIR/log -w start" > /dev/null
fi
