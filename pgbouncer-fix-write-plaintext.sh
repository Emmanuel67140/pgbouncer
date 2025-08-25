#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Script interactif : teste d'abord la connexion directe au backend,
# puis met à jour /srv/pgbouncer/userlist.txt avec les mots de passe en clair
# (format "user" "password"), reload PgBouncer, teste via pgbouncer, archive scripts.

USERLIST='/srv/pgbouncer/userlist.txt'
COMPOSE_DIR='/home/deploy/pgbouncer'
PSQL_IMAGE='postgres:15'

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

command -v docker >/dev/null || { echo "docker est requis"; exit 1; }
command -v sudo >/dev/null || { echo "sudo est requis"; exit 1; }

# Prompt pour les mots de passe (masqué)
read -r -p "Utilisateur PgBouncer admin (par defaut 'admin'): " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}
read -rsp "Mot de passe PgBouncer admin (sera utilisé pour RELOAD) : " ADMIN_PW
echo
read -r -p "Utilisateur applicatif (par defaut 'eddji_erp'): " APP_USER
APP_USER=${APP_USER:-eddji_erp}
read -rsp "Mot de passe application pour $APP_USER : " APP_PW
echo
read -r -p "Nom de la DB PgBouncer (pour mapping) (par defaut 'eddji_erpdb'): " APP_DB
APP_DB=${APP_DB:-eddji_erpdb}

log "Backup de $USERLIST..."
BACKUP="${USERLIST}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo cp -a "$USERLIST" "$BACKUP" 2>/dev/null || true
log "Backup: $BACKUP"

# Récupérer la ligne SHOW DATABASES pour la DB demandée
DB_LINE=$(docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
  psql -h 127.0.0.1 -p 6432 -U "$ADMIN_USER" -d pgbouncer -qAt -c "SHOW DATABASES;" 2>/dev/null \
  | awk -F'|' -v d="$APP_DB" '$1==d { gsub(/^[ \t]+|[ \t]+$/,"",$0); print; exit }' || true)

if [ -z "$DB_LINE" ]; then
  log "ERREUR: $APP_DB introuvable dans SHOW DATABASES (vérifie admin user/mdp)."
  log "Affichage de SHOW DATABASES brut pour debug:"
  docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
    psql -h 127.0.0.1 -p 6432 -U "$ADMIN_USER" -d pgbouncer -c "SHOW DATABASES;" || true
  exit 1
fi

# Extraire host/port/real_db
BACKEND_HOST=$(printf '%s' "$DB_LINE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
BACKEND_PORT=$(printf '%s' "$DB_LINE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
BACKEND_REALDB=$(printf '%s' "$DB_LINE" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')

log "Back-end trouvé: host=$BACKEND_HOST port=$BACKEND_PORT db=$BACKEND_REALDB"

# Test connexion directe au backend (vérifier mot de passe fourni)
log "Test connexion directe au backend (utilisateur: $APP_USER)..."
if docker run --rm --network host -e PGPASSWORD="$APP_PW" "$PSQL_IMAGE" \
    psql -h "$BACKEND_HOST" -p "$BACKEND_PORT" -U "$APP_USER" -d "$BACKEND_REALDB" -c "SELECT current_user, now();" >/dev/null 2>&1; then
  log "Connexion directe au backend: OK"
else
  log "ERREUR: connexion directe au backend FAILED -> mot de passe invalide ou accès bloqué."
  log "Abandon sans modifier userlist. Si tu es sûr, relance avec --force pour forcer l'écriture."
  log "Tu peux forcer: sudo $0 --force"
  exit 2
fi

# Si on arrive ici, on peut écrire la ligne en clair dans userlist
NEW_LINE_APP="\"$APP_USER\" \"$APP_PW\""
NEW_LINE_ADMIN="\"$ADMIN_USER\" \"$ADMIN_PW\""

# Écriture atomique (sauvegarde déjà faite)
TMP="/tmp/userlist.$$.tmp"
sudo sh -c "cat '$USERLIST' 2>/dev/null || true" > "$TMP" || true

# Remplacer ou ajouter admin
if grep -q -E "^\"$ADMIN_USER\" " "$TMP" 2>/dev/null; then
  sed -i "s/^\"$ADMIN_USER\" .*/$NEW_LINE_ADMIN/" "$TMP"
else
  printf '%s\n' "$NEW_LINE_ADMIN" >> "$TMP"
fi

# Remplacer ou ajouter app user
if grep -q -E "^\"$APP_USER\" " "$TMP" 2>/dev/null; then
  sed -i "s/^\"$APP_USER\" .*/$NEW_LINE_APP/" "$TMP"
else
  printf '%s\n' "$NEW_LINE_APP" >> "$TMP"
fi

# Déplacer en place (sudo)
sudo mv "$TMP" "$USERLIST"
sudo chown root:root "$USERLIST"
sudo chmod 640 "$USERLIST" || true
log "Userlist mise à jour (en clair)."

# RELOAD PgBouncer (ou restart si reload échoue)
log "Tentative RELOAD PgBouncer..."
if docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
   psql -h 127.0.0.1 -p 6432 -U "$ADMIN_USER" -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
  log "RELOAD OK"
else
  log "RELOAD failed -> restart container"
  sudo docker compose -f "${COMPOSE_DIR}/docker-compose.yml" down --remove-orphans || true
  sudo docker rm -f pgbouncer 2>/dev/null || true
  sudo docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --force-recreate --no-deps pgbouncer
  sleep 3
fi

# Diagnostics
log "SHOW SERVERS/POOLS/DATABASES (admin)..."
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
  psql -h 127.0.0.1 -p 6432 -U "$ADMIN_USER" -d pgbouncer -c "SHOW SERVERS;" -c "SHOW POOLS;" -c "SHOW DATABASES;" || true

log "Derniers logs PgBouncer (tail 200) :"
sudo docker logs --timestamps --tail 200 pgbouncer || true

log "Test via PgBouncer (app user)..."
if docker run --rm --network host -e PGPASSWORD="$APP_PW" "$PSQL_IMAGE" \
   psql -h 127.0.0.1 -p 6432 -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" >/dev/null 2>&1; then
  log "OK via PgBouncer: $APP_USER@$APP_DB"
else
  log "FAIL via PgBouncer: $APP_USER@$APP_DB"
fi

# Pack scripts existants pour archive (tar.gz)
ARCHIVE="/home/deploy/pgbouncer/pgbouncer-scripts-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
sudo tar -czf "$ARCHIVE" -C /home/deploy/pgbouncer . 2>/dev/null || true
log "Archive scripts: $ARCHIVE"

log "Terminé."
exit 0
