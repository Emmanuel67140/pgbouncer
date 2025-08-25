#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Try to source env from /etc/pgbouncer/pgbouncer.env or local pgbouncer.env
if [ -f /etc/pgbouncer/pgbouncer.env ]; then
  # shellcheck disable=SC1091
  . /etc/pgbouncer/pgbouncer.env
elif [ -f "$(dirname "$0")/pgbouncer.env" ]; then
  . "$(dirname "$0")/pgbouncer.env"
else
  echo "ERREUR: fichier \$ENVFILE introuvable ou /etc/pgbouncer/pgbouncer.env manquant"
  echo "Place un fichier /etc/pgbouncer/pgbouncer.env avec ADMIN_PW, APP_USER, APP_DB, APP_PW"
  exit 1
fi

# Defaults (au cas où)
COMPOSE_FILE="${COMPOSE_FILE:-/home/deploy/pgbouncer/docker-compose.yml}"
USERLIST_HOST="${USERLIST_HOST:-/srv/pgbouncer/userlist.txt}"

command -v docker >/dev/null || { echo "docker required"; exit 1; }
command -v md5sum >/dev/null || { echo "md5sum required"; exit 1; }

timestamp() { date -u +%Y%m%dT%H%M%SZ; }

# Backup existing userlist
if [ -f "$USERLIST_HOST" ]; then
  BACKUP="${USERLIST_HOST}.bak.$(timestamp)"
  sudo cp "$USERLIST_HOST" "$BACKUP"
  echo "Backup saved: $BACKUP"
fi

# compute md5 hashes (Postgres md5 style: md5(password+username))
ADMIN_HASH=$(printf '%s%s' "$ADMIN_PW" "admin" | md5sum | cut -d' ' -f1)
APP_HASH=$(printf '%s%s' "$APP_PW" "$APP_USER" | md5sum | cut -d' ' -f1)

# write atomically
TMP="$(mktemp /tmp/userlist.XXX)"
cat > "$TMP" <<USERLIST
"admin" "md5$ADMIN_HASH"
"$APP_USER" "md5$APP_HASH"
USERLIST

sudo mkdir -p "$(dirname "$USERLIST_HOST")"
sudo mv "$TMP" "$USERLIST_HOST"
sudo chown root:root "$USERLIST_HOST"
sudo chmod 644 "$USERLIST_HOST"
echo "Wrote $USERLIST_HOST:"
sudo sed -n '1,200p' "$USERLIST_HOST" || true

# try RELOAD via admin user; if fail, recreate container
if docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
     psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
  echo "RELOAD succeeded"
else
  echo "RELOAD failed -> restarting container"
  sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
  sudo docker rm -f pgbouncer 2>/dev/null || true
  sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
fi

# short verification (do not fail the script)
echo "--- inside container userlist ---"
sudo docker exec pgbouncer sh -lc 'cat /etc/pgbouncer/userlist.txt || true; stat -c "%U:%G %a %n" /etc/pgbouncer/userlist.txt || true'
echo "--- SHOW USERS (pgbouncer) ---"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW USERS;" || true
echo "--- test app connection ---"
docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1;" || true
echo "DONE"
