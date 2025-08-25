#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Usage: run this inside tmux/screen or with nohup to avoid Putty session drops.
# Example: tmux new -s pgbouncer   then run: /home/deploy/pgbouncer/01-pgbouncer-update.sh

# ------------------- CONFIGURE BELOW BEFORE RUN -------------------
ADMIN_PW='ercsEE376'     # <-- mot de passe admin (en clair)
APP_USER='eddji_erp'       # <-- user applicatif
APP_DB='eddji_erpdb'       # <-- base utilisée pour le test
APP_PW='ercsEE376'         # <-- mot de passe app (en clair)
# -----------------------------------------------------------------

# quick checks
command -v docker >/dev/null || { echo >&2 "docker is required"; exit 1; }
command -v md5sum >/dev/null || { echo >&2 "md5sum is required"; exit 1; }
command -v timeout >/dev/null || echo "warning: timeout not found; operations may hang"

# make an atomic backup and edit in /tmp
BACKUP="/srv/pgbouncer/userlist.txt.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo cp /srv/pgbouncer/userlist.txt "$BACKUP"
echo "Backup saved: $BACKUP"

TMP="/tmp/userlist.$$"
sudo cp /srv/pgbouncer/userlist.txt "$TMP"

update_or_add() {
  local user="$1" hash="$2" line
  line="\"$user\" \"md5$hash\""
  if grep -q "^\"$user\" " "$TMP"; then
    sudo sed -i "s/^\"$user\" .*/$line/" "$TMP"
  else
    printf "%s\n" "$line" | sudo tee -a "$TMP" >/dev/null
  fi
}

# compute and update admin
ADMIN_HASH=$(printf '%s%s' "$ADMIN_PW" "admin" | md5sum | cut -d' ' -f1)
update_or_add "admin" "$ADMIN_HASH"

# compute and update app user
APP_HASH=$(printf '%s%s' "$APP_PW" "$APP_USER" | md5sum | cut -d' ' -f1)
update_or_add "$APP_USER" "$APP_HASH"

# move into place atomically
sudo mv "$TMP" /srv/pgbouncer/userlist.txt
sudo chown root:root /srv/pgbouncer/userlist.txt
sudo chmod 644 /srv/pgbouncer/userlist.txt

echo "userlist updated (tail):"
sudo tail -n 20 /srv/pgbouncer/userlist.txt

# Reload pgbouncer via admin (use timeout to avoid hanging PuTTY)
echo "Reloading pgbouncer via admin user..."
if command -v timeout >/dev/null; then
  if ! timeout 10s docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
    psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
    echo "Reload failed; attempting container restart..."
    sudo docker compose -f /home/deploy/pgbouncer/docker-compose.yml down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f /home/deploy/pgbouncer/docker-compose.yml up -d --force-recreate --no-deps pgbouncer
  fi
else
  # no timeout available: try reload, but warn user
  if ! docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
    psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
    echo "Reload failed; attempting container restart..."
    sudo docker compose -f /home/deploy/pgbouncer/docker-compose.yml down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f /home/deploy/pgbouncer/docker-compose.yml up -d --force-recreate --no-deps pgbouncer
  fi
fi

# short tests (failure won't stop script)
echo "Testing admin..."
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW VERSION;" -c "SHOW USERS;" || echo "admin test failed"

echo "Testing app user..."
docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" || echo "app user test failed"

echo "Done."
