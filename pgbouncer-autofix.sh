#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ----------------- CONFIG (ADAPTE AVANT EXECUTION) -----------------
ADMIN_PW='ercsEE376'         # mot de passe admin pgbouncer
APP_USER='eddji_erp'         # user applicatif
APP_DB='eddji_erpdb'         # DB utilisée pour le test
APP_PW='ercsEE376'           # mot de passe app (si disponible, utile pour test direct)
COMPOSE_DIR='/home/deploy/pgbouncer'
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
DOCKER_PSQL_IMAGE='postgres:15'
PGB_HOST='127.0.0.1'
PGB_PORT='6432'
TIMEOUT_CMD='timeout'        # si absent, le script s'adapte (moins sûr)
# ------------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# Exécute une requête SQL sur la DB "pgbouncer" via psql dans un container
run_admin_sql() {
  local sql="$1"
  docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
    psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "$sql" 2>/dev/null || true
}

# 0) quick deps
command -v docker >/dev/null || { echo "docker requis"; exit 1; }
command -v awk >/dev/null || { echo "awk requis"; exit 1; }

# 1) is pgbouncer listening?
log "Vérification listener $PGB_HOST:$PGB_PORT..."
if ss -ltnp 2>/dev/null | grep -E ":${PGB_PORT}\\b" >/dev/null; then
  log "PgBouncer semble écouter sur $PGB_HOST:$PGB_PORT"
else
  log "Pas de listener détecté. Tentative de démarrage container via docker-compose..."
  sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer || true
  sleep 3
fi

# 2) fetch SHOW outputs
log "Récupération SHOW SERVERS/POOLS/DATABASES..."
SERVERS="$(run_admin_sql "SHOW SERVERS;")"
POOLS="$(run_admin_sql "SHOW POOLS;")"
DBS_RAW="$(run_admin_sql "SHOW DATABASES;")"

log "SHOW SERVERS (raw):"
printf '%s\n' "$SERVERS" | sed -n '1,200p' || true
log "SHOW POOLS (raw):"
printf '%s\n' "$POOLS" | sed -n '1,200p' || true
log "SHOW DATABASES (raw):"
printf '%s\n' "$DBS_RAW" | sed -n '1,200p' || true

# 3) If SHOW SERVERS is empty -> try RELOAD then restart if needed
if [ -z "$(printf '%s\n' "$SERVERS" | sed -n '/\S/p')" ]; then
  log "Aucune ligne dans SHOW SERVERS -> tentative de RELOAD..."
  if command -v $TIMEOUT_CMD >/dev/null; then
    $TIMEOUT_CMD 10s docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1 || true
  else
    docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
      psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1 || true
  fi
  sleep 3
  SERVERS="$(run_admin_sql "SHOW SERVERS;")"
  if [ -z "$(printf '%s\n' "$SERVERS" | sed -n '/\S/p')" ]; then
    log "Reload n'a pas résolu -> redémarrage du container pgbouncer..."
    sudo docker compose -f "$COMPOSE_FILE" down --remove-orphans || true
    sudo docker rm -f pgbouncer 2>/dev/null || true
    sudo docker compose -f "$COMPOSE_FILE" up -d --force-recreate --no-deps pgbouncer
    sleep 5
    SERVERS="$(run_admin_sql "SHOW SERVERS;")"
  fi
fi

# 4) if still empty, deeper diagnostics
if [ -z "$(printf '%s\n' "$SERVERS" | sed -n '/\S/p')" ]; then
  log "SHOW SERVERS toujours vide après reload/restart. Collecte diagnostics..."
  log "Logs pgbouncer (tail 200):"
  sudo docker logs --timestamps --tail 200 pgbouncer || true

  # try to parse backend host/port for the app DB from SHOW DATABASES output
  # expected format: name|host|port|database|force_user|pool_size|...
  BACKEND_HOST="$(printf '%s\n' "$DBS_RAW" | awk -F'|' -v db="$APP_DB" '$1~db {gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
  BACKEND_PORT="$(printf '%s\n' "$DBS_RAW" | awk -F'|' -v db="$APP_DB" '$1~db {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}')"

  # fallback tries if fields not found
  if [ -z "$BACKEND_HOST" ] || [ -z "$BACKEND_PORT" ]; then
    BACKEND_HOST="$(printf '%s\n' "$DBS_RAW" | grep -i "$APP_DB" | sed -E 's/\s*\|\s*/|/g' | cut -d'|' -f2 | head -n1 || true)"
    BACKEND_PORT="$(printf '%s\n' "$DBS_RAW" | grep -i "$APP_DB" | sed -E 's/\s*\|\s*/|/g' | cut -d'|' -f3 | head -n1 || true)"
  fi

  log "Back-end detecté (approx): host='$BACKEND_HOST' port='$BACKEND_PORT'"

  # 5) test TCP connect to backend
  if [ -n "$BACKEND_HOST" ] && [ -n "$BACKEND_PORT" ]; then
    log "Test TCP vers backend $BACKEND_HOST:$BACKEND_PORT..."
    if (bash -c "cat < /dev/null > /dev/tcp/$BACKEND_HOST/$BACKEND_PORT") 2>/dev/null; then
      log "TCP OK vers backend."
      # 6) test connexion psql directe au backend (utile pour valider user/pw)
      if [ -n "${APP_PW:-}" ]; then
        log "Essai connexion directe au backend (psql) en tant que $APP_USER@$APP_DB..."
        if docker run --rm --network host -e PGPASSWORD="$APP_PW" "$DOCKER_PSQL_IMAGE" \
           psql -h "$BACKEND_HOST" -p "$BACKEND_PORT" -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" >/dev/null 2>&1; then
          log "Connexion directe au backend réussie."
          log "Relance RELOAD pgbouncer pour forcer (éventuelle) re-découverte des servers..."
          docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL_IMAGE" \
            psql -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1 || true
          sleep 3
          SERVERS="$(run_admin_sql "SHOW SERVERS;")"
        else
          log "Échec connexion directe au backend -> vérifie user/pw côté serveur distant."
        fi
      else
        log "APP_PW non défini, saut du test psql direct."
      fi
    else
      log "TCP FAILED -> problème réseau / DNS / firewall vers $BACKEND_HOST:$BACKEND_PORT"
    fi
  else
    log "Impossible d'extraire host/port backend depuis SHOW DATABASES ; vérifie /srv/pgbouncer/pgbouncer.ini"
  fi
fi

# 7) print final status + guidance
log "Etat final (SHOW SERVERS/POOLS/DATABASES) :"
run_admin_sql "SHOW SERVERS;" | sed -n '1,200p' || true
run_admin_sql "SHOW POOLS;" | sed -n '1,200p' || true
run_admin_sql "SHOW DATABASES;" | sed -n '1,200p' || true

cat <<'MSG'
Actions manuelles recommandées si le problème persiste :
  - Vérifier /srv/pgbouncer/userlist.txt : hashes/md5 et users (admin/app).
  - Vérifier /srv/pgbouncer/pgbouncer.ini : lignes [databases] (host=... port=... dbname=...).
  - Depuis cette VM, tester "psql -h <backend> -p <port> -U <user> -d <db>" pour valider credentials et reachability.
  - Consulter les logs complets : sudo docker logs --timestamps pgbouncer
  - Exécuter ce script depuis tmux/screen/ nohup pour éviter déconnexions.
MSG

exit 0
