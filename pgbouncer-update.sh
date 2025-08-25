#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ENVFILE='/etc/pgbouncer/pgbouncer.env'
if [ ! -f "\$ENVFILE" ]; then
  echo "ERREUR: fichier \$ENVFILE introuvable. Edite-le et relance." >&2
  exit 2
fi

# shellcheck disable=SC1090
source "\$ENVFILE"

: \${ADMIN_PW:?ADMIN_PW doit être défini dans \$ENVFILE}
: \${APP_USER:=eddji_erp}
: \${APP_DB:=eddji_erpdb}
: \${APP_PW:?APP_PW doit être défini dans \$ENVFILE}
: \${COMPOSE_FILE:=/home/deploy/pgbouncer/docker-compose.yml}
: \${USERLIST_HOST:=/srv/pgbouncer/userlist.txt}

command -v md5sum >/dev/null || { echo "md5sum requis"; exit 1; }
command -v docker >/dev/null || { echo "docker requis"; exit 1; }

timestamp(){ date -u +%Y%m%dT%H%M%SZ; }

# backup existing userlist if present
sudo mkdir -p "$(dirname "$USERLIST_HOST")"
if [ -f "\$USERLIST_HOST" ]; then
  BACKUP="\$USERLIST_HOST.bak.\$(timestamp)"
  sudo cp "\$USERLIST_HOST" "\$BACKUP"
  echo "Backup saved: \$BACKUP"
fi

# compute hashes
ADMIN_HASH=\$(printf '%s%s' "\$ADMIN_PW" "admin" | md5sum | cut -d' ' -f1)
APP_HASH=\$(printf '%s%s' "\$APP_PW" "\$APP_USER" | md5sum | cut -d' ' -f1)

# prepare new userlist in temp
TMP=\$(mktemp /tmp/pgbouncer-userlist.XXXXXX)
cat > "\$TMP" <<USERLIST
"admin" "md5\$ADMIN_HASH"
"\$APP_USER" "md5\$APP_HASH"
USERLIST

# compare and move only if different (idempotent)
if [ -f "\$USERLIST_HOST" ]; then
  if sudo cmp -s "\$TMP" "\$USERLIST_HOST"; then
    echo "Pas de changement dans \$USERLIST_HOST"
    rm -f "\$TMP"
  else
    sudo mv "\$TMP" "\$USERLIST_HOST"
    sudo chown root:root "\$USERLIST_HOST"
    sudo chmod 644 "\$USERLIST_HOST"
    echo "Mise à jour \$USERLIST_HOST"
  fi
else
  sudo mv "\$TMP" "\$USERLIST_HOST"
  sudo chown root:root "\$USERLIST_HOST"
  sudo chmod 644 "\$USERLIST_HOST"
  echo "Création \$USERLIST_HOST"
fi

# attempt RELOAD via admin user (timeout pour éviter blocage)
if command -v timeout >/dev/null; then
  if timeout 10s docker run --rm --network host -e PGPASSWORD="\$ADMIN_PW" postgres:15 psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
    echo "RELOAD succeeded"
  else
    echo "RELOAD failed -> restart du container pgbouncer"
    sudo docker compose -f "\$COMPOSE_FILE" down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f "\$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
  fi
else
  # pas de timeout: on essaye quand même
  if docker run --rm --network host -e PGPASSWORD="\$ADMIN_PW" postgres:15 psql -qAt -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
    echo "RELOAD succeeded"
  else
    echo "RELOAD failed -> restart du container pgbouncer"
    sudo docker compose -f "\$COMPOSE_FILE" down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f "\$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
  fi
fi

# vérifications rapides (non bloquantes)
echo "=== inside container userlist ==="
sudo docker exec pgbouncer sh -lc 'cat /etc/pgbouncer/userlist.txt || true; stat -c "%U:%G %a %n" /etc/pgbouncer/userlist.txt || true'

echo "=== SHOW USERS (pgbouncer) ==="
docker run --rm --network host -e PGPASSWORD="\$ADMIN_PW" postgres:15 psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW USERS;" || true

echo "=== test app connection ==="
docker run --rm --network host -e PGPASSWORD="\$APP_PW" postgres:15 psql -h 127.0.0.1 -p 6432 -U "\$APP_USER" -d "\$APP_DB" -c "SELECT 1;" || true

echo "DONE: \$(timestamp)"
