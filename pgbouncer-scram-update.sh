#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ==== CONFIG (modifie si besoin) ====
ADMIN_PW='ercsEE376'                # mot de passe admin pgbouncer
APP_USER='eddji_erp'                # utilisateur applicatif (fallback)
APP_PW='ercsEE376'                  # mot de passe applicatif (fallback)
APP_DB='eddji_erpdb'                # base utilisée pour test direct
USERS_CSV='/home/deploy/pgbouncer/scram-users.csv'  # optional CSV user,password,db
ITERATIONS=4096
USERLIST='/srv/pgbouncer/userlist.txt'
COMPOSE_DIR='/home/deploy/pgbouncer'
PSQL_IMAGE='postgres:15'
# ====================================

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

command -v python3 >/dev/null || { echo "python3 requis"; exit 1; }
command -v docker >/dev/null || { echo "docker requis"; exit 1; }

FORCE=0
if [ "${1:-}" = "--force" ]; then
  FORCE=1
  log "Mode FORCE activé : le script écrasera userlist même si le test direct échoue"
fi

# génère SCRAM via un petit script python temporaire (retourne la string complète)
gen_scram() {
  local user="$1" pw="$2" iters="$3"
  local pyfile="/tmp/gen_scram_$$.py"
  cat > "$pyfile" <<'PY'
import sys,os,base64,hashlib,hmac
if len(sys.argv) < 3:
    print("", end=""); sys.exit(1)
pw = sys.argv[1]
iters = int(sys.argv[2])
salt = os.urandom(16)
salted = hashlib.pbkdf2_hmac('sha256', pw.encode('utf-8'), salt, iters)
client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
stored_key = hashlib.sha256(client_key).digest()
server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
b64salt = base64.b64encode(salt).decode('ascii')
b64stored = base64.b64encode(stored_key).decode('ascii')
b64server = base64.b64encode(server_key).decode('ascii')
# format Postgres: SCRAM-SHA-256$iterations:base64(salt)$base64(stored_key):base64(server_key)
print(f"SCRAM-SHA-256${iters}:{b64salt}${b64stored}:{b64server}")
PY
  local out
  out=$(python3 "$pyfile" -- "$pw" "$iters" 2>/tmp/gen_scram.err) || {
    log "Erreur python gen_scram — voir /tmp/gen_scram.err"
    rm -f "$pyfile"
    return 1
  }
  rm -f "$pyfile"
  printf '%s' "$out"
}

# récupère la ligne SHOW DATABASES correspondante à dbname
get_db_line() {
  local dbname="$1"
  docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
    psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -qAt -c "SHOW DATABASES;" \
    | awk -F'|' -v d="$dbname" '$1==d { gsub(/^[ \t]+|[ \t]+$/,"",$0); print; exit }'
}

test_direct_backend() {
  local host="$1" port="$2" user="$3" db="$4" pass="$5"
  log "Test direct backend: psql -h $host -p $port -U $user -d $db ..."
  if docker run --rm --network host -e PGPASSWORD="$pass" "$PSQL_IMAGE" \
     psql -h "$host" -p "$port" -U "$user" -d "$db" -c "SELECT 1;" >/dev/null 2>&1; then
    log "Connexion directe au backend OK"
    return 0
  else
    log "Connexion directe au backend FAILED"
    return 1
  fi
}

# mise à jour atomique userlist (utilise awk pour éviter problèmes de / dans scram)
update_userlist() {
  local user="$1" scram="$2"
  local tmp="/tmp/userlist.$$"
  sudo cp -a "$USERLIST" "$tmp" 2>/dev/null || echo -n "" > "$tmp"
  local line="\"$user\" \"$scram\""
  # produce new temp file with replacement or append if not found
  awk -v u="$user" -v line="$line" '
    BEGIN{ pat="^\""u"\" " ; found=0 }
    $0 ~ pat { print line; found=1; next }
    { print }
    END{ if (!found) print line }
  ' "$tmp" > "${tmp}.new"
  sudo mv "${tmp}.new" "$tmp"
  sudo mv "$tmp" "$USERLIST"
  sudo chown root:root "$USERLIST"
  sudo chmod 644 "$USERLIST"
  log "userlist sauvegardé: $USERLIST"
}

process_one() {
  local u="$1" p="$2" dbname="$3"
  local dbl
  dbl=$(get_db_line "$dbname" || true)
  if [ -z "$dbl" ]; then
    log "ERROR: $dbname non trouvé dans SHOW DATABASES (pgbouncer)."
    return 2
  fi
  local host port realdb
  host=$(printf '%s' "$dbl" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
  port=$(printf '%s' "$dbl" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
  realdb=$(printf '%s' "$dbl" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
  log "Backend detected for $dbname -> $host:$port (db=$realdb)"

  if ! test_direct_backend "$host" "$port" "$u" "$realdb" "$p"; then
    if [ "$FORCE" -ne 1 ]; then
      log "Skipping $u: direct backend auth failed. Use --force to override (risqué)"
      return 3
    else
      log "Force enabled: proceeding despite direct auth failure."
    fi
  fi

  scram=$(gen_scram "$u" "$p" "$ITERATIONS") || { log "Erreur génération SCRAM pour $u"; return 4; }
  update_userlist "$u" "$scram"
  return 0
}

# build list
ENTRIES=()
if [ -f "$USERS_CSV" ] && [ -s "$USERS_CSV" ]; then
  log "Lecture CSV $USERS_CSV ..."
  while IFS=',' read -r u p db; do
    [ -z "${u:-}" ] && continue
    ENTRIES+=("$u|$p|$db")
  done < "$USERS_CSV"
else
  ENTRIES+=("${APP_USER}|${APP_PW}|${APP_DB}")
fi

# backup
BACKUP="${USERLIST}.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo cp -a "$USERLIST" "$BACKUP" 2>/dev/null || true
log "Backup saved: $BACKUP"

SKIPPED=0
for e in "${ENTRIES[@]}"; do
  u=${e%%|*}
  rest=${e#*|}
  p=${rest%%|*}
  db=${rest#*|}
  log "Processing $u -> $db ..."
  if process_one "$u" "$p" "$db"; then
    log "OK: $u updated"
  else
    log "FAILED or SKIPPED: $u"
    SKIPPED=$((SKIPPED+1))
  fi
done

# try reload
log "Attempt RELOAD PgBouncer..."
if docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
   psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "RELOAD;" >/dev/null 2>&1; then
  log "RELOAD OK"
else
  log "RELOAD failed -> restarting container"
  sudo docker compose -f "${COMPOSE_DIR}/docker-compose.yml" down --remove-orphans || true
  sudo docker rm -f pgbouncer 2>/dev/null || true
  sudo docker compose -f "${COMPOSE_DIR}/docker-compose.yml" up -d --force-recreate --no-deps pgbouncer || true
  sleep 3
fi

# diagnostics (non-fatal)
log "SHOW SERVERS / POOLS / DATABASES (admin):"
docker run --rm --network host -e PGPASSWORD="$ADMIN_PW" "$PSQL_IMAGE" \
  psql -h 127.0.0.1 -p 6432 -U admin -d pgbouncer -c "SHOW SERVERS;" -c "SHOW POOLS;" -c "SHOW DATABASES;" || true

log "Derniers logs PgBouncer (tail 200):"
sudo docker logs --timestamps --tail 200 pgbouncer || true

log "Tests via PgBouncer:"
for e in "${ENTRIES[@]}"; do
  u=${e%%|*}; rest=${e#*|}; p=${rest%%|*}; db=${rest#*|}
  if docker run --rm --network host -e PGPASSWORD="$p" "$PSQL_IMAGE" \
     psql -h 127.0.0.1 -p 6432 -U "$u" -d "$db" -c "SELECT current_user, now();" >/dev/null 2>&1; then
    log "OK via PgBouncer for $u@$db"
  else
    log "FAIL via PgBouncer for $u@$db"
  fi
done

log "Script terminé. Skipped=$SKIPPED"
exit 0
