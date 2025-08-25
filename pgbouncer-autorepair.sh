#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------- CONFIG - EDIT BEFORE RUN -----------------
ADMIN_PW='ercsEE376'        # mot de passe admin pgbouncer (clair)
APP_USER='eddji_erp'        # user applicatif à vérifier/mettre à jour
APP_DB='eddji_erpdb'        # DB utilisée pour test
APP_PW='ercsEE376'          # mot de passe app (laisser vide si non disponible)
COMPOSE_DIR='/home/deploy/pgbouncer'
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DOCKER_PSQL_IMAGE='postgres:15'
PGB_HOST='127.0.0.1'
PGB_PORT='6432'
TIMEOUT_CMD='timeout'       # "timeout" recommandé pour éviter hangs (install: coreutils)
# -----------------------------------------------------------

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# run SQL on pgbouncer admin DB (returns stdout or empty)
run_admin_sql() {
  local sql="$1"
  if command -v $TIMEOUT_CMD >/dev/null 2>&1; then
    $TIMEOUT_CMD 10s docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "$sql" 2>/dev/null || true
  else
    docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "$sql" 2>/dev/null || true
  fi
}

# update or append a "userlist" md5 line in tmp file
update_user_in_tmp() {
  local tmp="$1" user="$2" pass="$3"
  local hash line
  hash=$(printf '%s%s' "$pass" "$user" | md5sum | awk '{print $1}')
  line="\"$user\" \"md5$hash\""
  if grep -q -E "^\"${user}\" " "$tmp"; then
    sed -i -E "s/^\"${user}\" .*/${line}/" "$tmp"
  else
    printf '%s\n' "$line" >> "$tmp"
  fi
}

# ensure docker present
command -v docker >/dev/null 2>&1 || { echo "docker manquant"; exit 1; }

log "1) Vérifier que pgbouncer écoute $PGB_HOST:$PGB_PORT..."
if ss -ltnp 2>/dev/null | grep -E ":${PGB_PORT}\\b" >/dev/null; then
  log "PgBouncer: listener détecté."
else
  log "Aucun listener détecté — tentative de (re)lancement via docker-compose..."
  sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer || true
  sleep 3
fi

log "2) Récupération des états SHOW SERVERS/POOLS/DATABASES..."
SERVERS="$(run_admin_sql "SHOW SERVERS;")"
POOLS="$(run_admin_sql "SHOW POOLS;")"
DBS_RAW="$(run_admin_sql "SHOW DATABASES;")"

log "SHOW SERVERS (raw):"
printf '%s\n' "$SERVERS" | sed -n '1,200p' || true
log "SHOW POOLS (raw):"
printf '%s\n' "$POOLS" | sed -n '1,200p' || true
log "SHOW DATABASES (raw):"
printf '%s\n' "$DBS_RAW" | sed -n '1,200p' || true

# If SHOW SERVERS empty => try to repair
if [ -z "$(printf '%s\n' "$SERVERS" | sed -n '/\S/p')" ]; then
  log "Aucune entrée dans SHOW SERVERS -> tentative de réparation automatique."

  # 3) Backup + update /srv/pgbouncer/userlist.txt (admin + app if APP_PW set)
  if [ -f /srv/pgbouncer/userlist.txt ]; then
    BACKUP="/srv/pgbouncer/userlist.txt.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    sudo cp /srv/pgbouncer/userlist.txt "$BACKUP"
    log "Backup userlist: $BACKUP"
  else
    sudo mkdir -p /srv/pgbouncer
    sudo touch /srv/pgbouncer/userlist.txt
    sudo chown root:root /srv/pgbouncer/userlist.txt
  fi

  TMP="/tmp/userlist.$$.txt"
  sudo cp /srv/pgbouncer/userlist.txt "$TMP"
  sudo chown "$USER":"$USER" "$TMP" || true

  log "Mise à jour userlist: admin"
  update_user_in_tmp "$TMP" "admin" "$ADMIN_PW"

  if [ -n "${APP_PW:-}" ]; then
    log "Mise à jour userlist: $APP_USER"
    update_user_in_tmp "$TMP" "$APP_USER" "$APP_PW"
  else
    log "APP_PW vide - saut mise à jour de $APP_USER"
  fi

  sudo mv "$TMP" /srv/pgbouncer/userlist.txt
  sudo chown root:root /srv/pgbouncer/userlist.txt
  sudo chmod 644 /srv/pgbouncer/userlist.txt
  log "userlist.txt mis à jour, permissions fixées."

  # 4) RELOAD
  log "Tentative RELOAD pgbouncer (admin)..."
  if command -v $TIMEOUT_CMD >/dev/null 2>&1; then
    if ! $TIMEOUT_CMD 10s docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
      log "Reload échoué (ou timeout). On va redémarrer le container."
      sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
      sudo docker rm -f pgbouncer 2>/dev/null || true
      sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
      sleep 5
    else
      sleep 3
    fi
  else
    # pas de timeout disponible
    if ! docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
      log "Reload échoué. Restart container..."
      sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
      sudo docker rm -f pgbouncer 2>/dev/null || true
      sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
      sleep 5
    else
      sleep 3
    fi
  fi

  # re-read
  SERVERS="$(run_admin_sql "SHOW SERVERS;")"
  if [ -n "$(printf '%s\n' "$SERVERS" | sed -n '/\S/p')" ]; then
    log "SHOW SERVERS contient maintenant des lignes — OK."
  else
    log "SHOW SERVERS toujours vide après reload/restart -> collecte diagnostique et tests réseau."
    log "Derniers logs pgbouncer (tail 200):"
    sudo docker logs --timestamps --tail 200 pgbouncer || true

    # extract backend host/port from SHOW DATABASES: expected name|host|port|dbname|...
    BACKEND_HOST="$(printf '%s\n' "$DBS_RAW" | awk -F'|' -v db="$APP_DB" '$1~db {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    BACKEND_PORT="$(printf '%s\n' "$DBS_RAW" | awk -F'|' -v db="$APP_DB" '$1~db {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}')"
    # fallback parsing
    if [ -z "$BACKEND_HOST" ] || [ -z "$BACKEND_PORT" ]; then
      BACKEND_HOST="$(printf '%s\n' "$DBS_RAW" | grep -i "$APP_DB" | sed -E 's/\s*\|\s*/|/g' | cut -d'|' -f2 | head -n1 || true)"
      BACKEND_PORT="$(printf '%s\n' "$DBS_RAW" | grep -i "$APP_DB" | sed -E 's/\s*\|\s*/|/g' | cut -d'|' -f3 | head -n1 || true)"
    fi

    log "Back-end approx: host='$BACKEND_HOST' port='$BACKEND_PORT'"

    # test TCP
    if [ -n "$BACKEND_HOST" ] && [ -n "$BACKEND_PORT" ]; then
      log "Test TCP vers $BACKEND_HOST:$BACKEND_PORT..."
      if (bash -c "cat < /dev/null > /dev/tcp/$BACKEND_HOST/$BACKEND_PORT") 2>/dev/null; then
        log "TCP OK vers backend"
        # test psql directe si APP_PW fourni
        if [ -n "${APP_PW:-}" ]; then
          log "Tentative connection directe psql au backend en tant que $APP_USER..."
          if docker run --rm --network host -e PGPASSWORD="$APP_PW" "$DOCKER_PSQL_IMAGE" \
             psql -h "$BACKEND_HOST" -p "$BACKEND_PORT" -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" >/dev/null 2>&1; then
            log "Connexion directe au backend OK. RELOAD pgbouncer (nouvelle tentative)..."
            docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
              psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1 || true
            sleep 3
            SERVERS="$(run_admin_sql "SHOW SERVERS;")"
          else
            log "Connexion directe au backend échoue -> vérifier user/mdp côté serveur distant."
          fi
        else
          log "APP_PW introuvable -> saut test psql direct."
        fi
      else
        log "Échec TCP -> problème réseau/DNS/firewall vers le backend."
      fi
    else
      log "Impossible d'extraire host/port backend depuis SHOW DATABASES ; vérifier /srv/pgbouncer/pgbouncer.ini"
    fi
  fi
else
  log "SHOW SERVERS non vide au départ -> pas d'action corrective nécessaire."
fi

# Final: print status
log "=== ETAT FINAL ==="
log "SHOW SERVERS:"
run_admin_sql "SHOW SERVERS;" | sed -n '1,200p' || true
log "SHOW POOLS:"
run_admin_sql "SHOW POOLS;" | sed -n '1,200p' || true
log "SHOW DATABASES:"
run_admin_sql "SHOW DATABASES;" | sed -n '1,200p' || true

cat <<'MSG'
Si le problème persiste :
 - Vérifier /srv/pgbouncer/userlist.txt : les lignes doivent être du type:
     "username" "md5<md5(pass+user)>"
 - Vérifier /srv/pgbouncer/pgbouncer.ini : [databases] host=... port=... dbname=...
 - Vérifier reachability & credentials directement depuis la VM:
     docker run --rm --network host -e PGPASSWORD='APP_PW' postgres:15 \
       psql -h <backend_host> -p <backend_port> -U <user> -d <db>
 - Consulter logs complets: sudo docker logs --timestamps pgbouncer
 - Exécuter ce script dans un tmux/screen (évite les coupures Putty)
MSG

exit 0
