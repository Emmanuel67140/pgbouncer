#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ENVFILE=/etc/pgbouncer/pgbouncer.env
if [ ! -f "$ENVFILE" ]; then
  echo "ERREUR: fichier ENV introuvable: $ENVFILE" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$ENVFILE"

# Sanity checks
command -v docker >/dev/null || { echo "docker absent"; exit 3; }
command -v md5sum >/dev/null || { echo "md5sum absent"; exit 4; }

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# Backup userlist if exists
if [ -f "$USERLIST_HOST" ]; then
  sudo mkdir -p "$(dirname "$USERLIST_HOST")"
  BACKUP="${USERLIST_HOST}.bak.$(timestamp)"
  sudo cp "$USERLIST_HOST" "$BACKUP"
  echo "Backup saved: $BACKUP"
fi

# Compute hashes (md5 used by pgbouncer)
ADMIN_HASH=$(printf '%s%s' "$ADMIN_PW" "admin" | md5sum | cut -d' ' -f1)
APP_HASH=$(printf '%s%s' "$APP_PW" "$APP_USER" | md5sum | cut -d' ' -f1)

# Prepare tmp file and write userlist atomically
TMP="$(mktemp /tmp/userlist.XXXXX)"
cat > "$TMP" <<USERLIST
"admin" "md5$ADMIN_HASH"
"$APP_USER" "md5$APP_HASH"
USERLIST

sudo mkdir -p "$(dirname "$USERLIST_HOST")"
sudo mv "$TMP" "$USERLIST_HOST"
sudo chown root:root "$USERLIST_HOST"
sudo chmod 644 "$USERLIST_HOST"
echo "Wrote $USERLIST_HOST:"
sudo sed -n '1,200p' "$USERLIST_HOST"

# Try RELOAD via pgBouncer admin; if fails restart container
echo "Attempting RELOAD via admin..."
if docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
     psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
  echo "RELOAD ok"
else
  echo "RELOAD failed -> restarting container"
  sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
  sudo docker rm -f pgbouncer 2>/dev/null || true
  sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
fi

# Short verification (non-fatal)
echo "=== inside container userlist ==="
sudo docker exec pgbouncer sh -lc 'cat /etc/pgbouncer/userlist.txt || true; stat -c "%U:%G %a %n" /etc/pgbouncer/userlist.txt || true'
echo "=== SHOW USERS (pgbouncer) ==="
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW USERS;" || true
echo "=== test app connection ==="
docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1;" || true
echo "DONE"
