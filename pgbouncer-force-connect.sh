#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# --------- EDIT BEFORE RUN if needed ----------
ADMIN_PW='ercsEE376'         # mot de passe admin pgbouncer (clair)
APP_USER='eddji_erp'         # user applicatif
APP_DB='eddji_erpdb'         # db pour test
APP_PW='ercsEE376'           # mdp app (clair)
TRIES=3                      # nombre de tentatives de connexion applicative
SLEEP_PER_CONN=1             # secondes de pg_sleep par connexion (laisser le serveur créer la connexion)
DOCKER_PSQL='postgres:15'
PGB_HOST='127.0.0.1'
PGB_PORT='6432'
COMPOSE_FILE='/home/deploy/pgbouncer/docker-compose.yml'
# ----------------------------------------------

log(){ printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

command -v docker >/dev/null 2>&1 || { echo "docker requis"; exit 1; }

log "Etat avant actions : SHOW SERVERS / SHOW POOLS / SHOW DATABASES"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW SERVERS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW POOLS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW DATABASES;" || true

# sanity: userlist presence
if ! sudo grep -q -E "^\"${APP_USER}\" " /srv/pgbouncer/userlist.txt 2>/dev/null; then
  log "WARN: /srv/pgbouncer/userlist.txt ne contient pas d'entrée pour ${APP_USER}"
  log "Affichage /srv/pgbouncer/userlist.txt (tail):"
  sudo tail -n 20 /srv/pgbouncer/userlist.txt || true
fi

log "Tentative de forcer ${TRIES} connexions applicatives (psql -> pgbouncer -> backend)."
for i in $(seq 1 $TRIES); do
  log "Tentative $i/$TRIES : ouverture d'une session client via PgBouncer..."
  # on exécute pg_sleep côté serveur pour laisser le temps à PgBouncer de créer la connexion serveur
  docker run --rm --network host -e PGPASSWORD="$APP_PW" "$DOCKER_PSQL" \
    psql -v ON_ERROR_STOP=1 -h "$PGB_HOST" -p "$PGB_PORT" -U "$APP_USER" -d "$APP_DB" \
    -c "SELECT current_user, inet_client_addr(); SELECT pg_sleep(${SLEEP_PER_CONN});" >/dev/null 2>&1 || {
      log "Connexion applicative $i a échoué (vérifier mdp/DB)."
    }
  # petit délai pour laisser pgbouncer établir pool/servers
  sleep 1
done

log "Relire SHOW SERVERS / SHOW POOLS / SHOW DATABASES après tentatives :"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW SERVERS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW POOLS;" || true
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$DOCKER_PSQL" \
  psql -qAt -h "$PGB_HOST" -p "$PGB_PORT" -U admin -d pgbouncer -c "SHOW DATABASES;" || true

log "Affichage rapide des derniers logs pgbouncer (tail 200) pour voir erreurs auth/connect:"
sudo docker logs --timestamps --tail 200 pgbouncer || true

log "Si SHOW SERVERS est toujours vide :"
cat <<'EOT'
 - Cela peut être normal si aucune connexion serveur n'a été ouverte (PgBouncer ouvre serveur-side à la demande).
 - Si malgré des connexions clients SHOW SERVERS reste vide, vérifier :
     * /srv/pgbouncer/userlist.txt (présence de "admin" et du user applicatif avec md5 correct)
     * /srv/pgbouncer/pgbouncer.ini : vérifier entries [databases] et s'il y a "user=" ou "auth" particuliers
     * logs pgbouncer pour "password" / "auth" / "cannot" messages.
 - Pour tests manuels :
     * Connexion directe via PgBouncer (depuis la VM) :
       docker run --rm --network host -e PGPASSWORD='APP_PW' postgres:15 \\
         psql -h 127.0.0.1 -p 6432 -U APP_USER -d APP_DB -c "SELECT current_user, now();"
EOT

log "Terminé."
exit 0
