#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ADMIN_PW='ercsEE376'
APP_USER='eddji_erp'
APP_PW='ercsEE376'
APP_DB='eddji_erpdb'
BACKEND_HOST='un13134-001.eu.clouddb.ovh.net'
BACKEND_PORT='35929'
PGBOUNCER_HOST='127.0.0.1'
PGBOUNCER_PORT='6432'

log(){ printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

command -v docker >/dev/null || { echo "docker required"; exit 1; }

log "1) Test connexion directe au backend (psql via docker)"
docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
  psql -h "$BACKEND_HOST" -p "$BACKEND_PORT" -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" || log "Direct backend connection: FAILED"

log "2) Test connexion via PgBouncer (admin)"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" postgres:15 \
  psql -h "$PGBOUNCER_HOST" -p "$PGBOUNCER_PORT" -U admin -d pgbouncer -c "SHOW DATABASES;" || log "PgBouncer admin test: FAILED"

log "3) Test connexion via PgBouncer (app user)"
docker run --rm --network host -e PGPASSWORD="$APP_PW" postgres:15 \
  psql -h "$PGBOUNCER_HOST" -p "$PGBOUNCER_PORT" -U "$APP_USER" -d "$APP_DB" -c "SELECT current_user, now();" || log "PgBouncer app test: FAILED"

log "4) Vérifier logs récents PgBouncer (si conteneur nommé 'pgbouncer' existant)"
if docker ps --format '{{.Names}}' | grep -q '^pgbouncer$'; then
  docker logs --tail 200 pgbouncer || true
else
  log "Conteneur pgbouncer non trouvé. Skip docker logs."
fi

log "5) Vérifier connectivité TCP au backend"
if command -v nc >/dev/null; then
  nc -vz "$BACKEND_HOST" "$BACKEND_PORT" || log "TCP connect to backend failed"
else
  log "nc not installed; skipping TCP check"
fi

log "Diagnostics completed."
