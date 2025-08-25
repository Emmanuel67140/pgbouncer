#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------ EDIT IF NEEDED ------------------
ADMIN_PW='ercsEE376'                       # mot de passe admin clear (utilisé pour RELOAD)
APP_USER='eddji_erp'                       # nom user applicatif
APP_DB='eddji_erpdb'                       # base de test
APP_PW='ercsEE376'                         # mot de passe app clear
REMOTE_HOST='un13134-001.eu.clouddb.ovh.net' # serveur Postgres distant (vide pour skip)
REMOTE_PORT='35929'
REMOTE_DB_USER="$APP_USER"                 # user pour exécuter ALTER ROLE à distance
COMPOSE_FILE="/home/deploy/pgbouncer/docker-compose.yml"
USERLIST_HOST="/srv/pgbouncer/userlist.txt"
TIMEOUT_CMD=$(command -v timeout || true)
# ---------------------------------------------------

timestamp(){ date -u +%Y%m%dT%H%M%SZ; }

echo "=== PgBouncer finalize $(timestamp) ==="

# checks
command -v docker >/dev/null || { echo "docker required"; exit 1; }
command -v md5sum >/dev/null || { echo "md5sum required"; exit 1; }

# 1) backup current file if present
if [ -f "$USERLIST_HOST" ]; then
  BACKUP="${USERLIST_HOST}.bak.$(timestamp)"
  sudo cp "$USERLIST_HOST" "$BACKUP"
  echo "Backup saved: $BACKUP"
else
  echo "No existing $USERLIST_HOST, will create a new one."
fi

# 2) ensure remote Postgres stores md5 (optional)
if [ -n "${REMOTE_HOST:-}" ]; then
  echo "→ Ensuring remote role uses md5 on ${REMOTE_HOST}:${REMOTE_PORT} ..."
  docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
    psql -qAt -h "$REMOTE_HOST" -p "$REMOTE_PORT" -U "$REMOTE_DB_USER" -d "$APP_DB" \
    -c "SET password_encryption = 'md5'; ALTER ROLE \"$APP_USER\" WITH PASSWORD '$APP_PW';" >/dev/null 2>&1 || \
    echo "Warning: remote ALTER ROLE failed — check remote connectivity/creds (but continuing)."
else
  echo "Skipping remote ALTER ROLE (REMOTE_HOST empty)."
fi

# 3) compute md5(pass||user)
APP_HASH=$(printf '%s%s' "$APP_PW" "$APP_USER" | md5sum | cut -d' ' -f1)
ADMIN_HASH=$(printf '%s%s' "$ADMIN_PW" "admin" | md5sum | cut -d' ' -f1)
echo "Computed: admin md5${ADMIN_HASH}"
echo "Computed: ${APP_USER} md5${APP_HASH}"

# 4) write atomically
TMP="$(mktemp /tmp/userlist.XXXXXX)"
cat > "$TMP" <<EOF
"admin" "md5${ADMIN_HASH}"
"${APP_USER}" "md5${APP_HASH}"
EOF

sudo mv "$TMP" "$USERLIST_HOST"
sudo chown root:root "$USERLIST_HOST"
sudo chmod 644 "$USERLIST_HOST"
echo "Wrote $USERLIST_HOST (owner root:root mode 644). Contents:"
sudo sed -n '1,200p' "$USERLIST_HOST"
echo

# 5) Try RELOAD via admin (fast). Use timeout if available to avoid hanging sessions.
echo "Attempting RELOAD via admin ..."
RELOAD_CMD=(docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;")
if [ -n "$TIMEOUT_CMD" ]; then
  if ! timeout 10s "${RELOAD_CMD[@]}" >/dev/null 2>&1; then
    echo "RELOAD failed or timed out -> restarting container..."
    sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
  else
    echo "RELOAD succeeded."
  fi
else
  # no timeout available
  if ! "${RELOAD_CMD[@]}" >/dev/null 2>&1; then
    echo "RELOAD failed -> restarting container..."
    sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
  else
    echo "RELOAD succeeded."
  fi
fi

# 6) small wait & verification
echo "Waiting briefly for PgBouncer to respond..."
sleep 2

echo "Show active users (pgbouncer SHOW USERS):"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
  psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW USERS;" || echo "SHOW USERS failed"

echo "Testing application login through PgBouncer (SELECT 1):"
if docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
     psql -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -c "SELECT 1;" >/dev/null 2>&1; then
  echo "APP TEST OK: connection through PgBouncer works"
else
  echo "APP TEST FAILED: see container logs"
  sudo docker logs --timestamps --tail 80 pgbouncer | egrep -i 'SCRAM|wrong password type|auth_file|userlist|Permission denied|server login failed|invalid command' || true
  exit 2
fi

echo "=== DONE $(timestamp) ==="
