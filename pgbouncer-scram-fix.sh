#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ------------------ CONFIG (EDIT BEFORE RUN IF NEEDED) ------------------
ADMIN_PW='ercsEE376'     # mot de passe admin pgbouncer (en clair)
APP_USER='eddji_erp'     # user applicatif
APP_DB='eddji_erpdb'     # db pour test
APP_PW='ercsEE376'       # mot de passe app (en clair)
DOCKER_PSQL='postgres:15'
PGB_HOST='127.0.0.1'
PGB_PORT='6432'
COMPOSE_FILE='/home/deploy/pgbouncer/docker-compose.yml'
FORCE_CONN_COUNT=3
SLEEP_PER_CONN=1
# -----------------------------------------------------------------------

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# sanity checks
command -v docker >/dev/null 2>&1 || { echo "docker requis"; exit 1; }
[ -d /srv/pgbouncer ] || { echo "/srv/pgbouncer absent"; exit 1; }

log "Backup current userlist..."
BACKUP="/srv/pgbouncer/userlist.txt.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo cp /srv/pgbouncer/userlist.txt "$BACKUP"
log "Backup saved: $BACKUP"

log "Showing current /srv/pgbouncer/userlist.txt (tail 40):"
sudo tail -n 40 /srv/pgbouncer/userlist.txt || true

log "Updating userlist with CLEAR passwords for admin and $APP_USER"
TMP="/tmp/userlist.$$.tmp"
sudo cp /srv/pgbouncer/userlist.txt "$TMP"

# helper to replace or append a line: "user" "password"
replace_or_add_line() {
  local u="$1" pw="$2" line
  line="\"${u}\" \"${pw}\""
  if sudo grep -q -E "^\"${u}\" " "$TMP"; then
    sudo sed -i "s/^\"${u}\" .*/${line}/" "$TMP"
  else
    printf '%s\n' "$line" | sudo tee -a "$TMP" > /dev/null
  fi
}

replace_or_add_line "admin" "$ADMIN_PW"
replace_or_add_line "$APP_USER" "$APP_PW"

log "Moving updated userlist into place (atomic mv)..."
sudo mv "$TMP" /srv/pgbouncer/userlist.txt
sudo chown root:root /srv/pgbouncer/userlist.txt
sudo chmod 600 /srv/pgbouncer/userlist.txt
log "New userlist (tail 40):"
sudo tail -n 40 /srv/pgbouncer/userlist.txt || true

# Try reload via pgbouncer admin
log "Trying RELOAD via admin user..."
if docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
     psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
  log "RELOAD ok."
else
  log "RELOAD failed — restarting container pgbouncer..."
  sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
  sudo docker rm -f pgbouncer 2>/dev/null || true
  sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
  sleep 3
fi

# Force a few app connections via PgBouncer so pooler opens server connections
log "Forcer ${FORCE_CONN_COUNT} connexions applicatives via PgBouncer (will run pg_sleep on server side)"
for i in $(seq 1 $FORCE_CONN_COUNT); do
  log "Client attempt $i: connecting ${APP_USER}@${APP_DB} via pgbouncer..."
  docker run --rm --network host -e PGPASSWORD="$APP_PW" "$DOCKER_PSQL" \
    psql -v ON_ERROR_STOP=1 -h "$PGB_HOST" -p "$PGB_PORT" -U "$APP_USER" -d "$APP_DB" \
    -c "SELECT current_user, inet_client_addr();" -c "SELECT pg_sleep(${SLEEP_PER_CONN});" >/dev/null 2>&1 || {
      log "Connexion client $i échouée (vérifier mdp/DB)."
    }
  sleep 1
done

log "Afficher SHOW SERVERS / SHOW POOLS / SHOW DATABASES via admin:"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW SERVERS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW POOLS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW DATABASES;" || true

log "Derniers logs pgbouncer (tail 200):"
sudo docker logs --timestamps --tail 200 pgbouncer || true

cat <<'EOF'
=== NOTE SECURITE ===
Ce script a placé des mots de passe en clair dans /srv/pgbouncer/userlist.txt pour permettre
à PgBouncer d'effectuer l'authentification SCRAM auprès du serveur backend.
Ceci est pratique pour réparation rapide MAIS le fichier contient des secrets en clair.

Actions recommandées ensuite :
 - restreindre l'accès au fichier (déjà chmod 600 fait ci-dessus).
 - déplacer userlist dans un emplacement chiffré si possible.
 - envisager côté serveur backend de permettre md5 ou de générer et stocker scram hashes compatibles.
 - revoir rotation & sauvegarde du fichier, et audit accès.

Si tu veux que je convertisse les mots de passe en hash scram-sha-256 pour stocker dans userlist (me demander),
je peux fournir la procédure mais elle est un peu plus longue.
EOF

log "Terminé."
exit 0
