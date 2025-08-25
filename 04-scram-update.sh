#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Safe SCRAM update: dry-run by default. Use --apply to write userlist.
FORCE_APPLY=0
if [ "${1:-}" = "--apply" ]; then
  FORCE_APPLY=1
fi

USER='eddji_erp'
PW='ercsEE376'
ITER=4096
USERLIST='/srv/pgbouncer/userlist.txt'
TMP="/tmp/userlist.scram.$$"

if [ "$FORCE_APPLY" -eq 0 ]; then
  echo "Dry-run mode. Generate SCRAM and show the replacement line. To apply: $0 --apply"
fi

SCRAM=$(APP_PW="$PW" APP_USER="$USER" ITERATIONS="$ITER" python3 - <<'PY'
import os,base64,hashlib,hmac,secrets
pw = os.environ['APP_PW']
iters = int(os.environ.get('ITERATIONS','4096'))
salt = secrets.token_bytes(16)
salted = hashlib.pbkdf2_hmac('sha256', pw.encode('utf-8'), salt, iters)
client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
stored_key = hashlib.sha256(client_key).digest()
server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
b64_salt = base64.b64encode(salt).decode('ascii')
b64_stored = base64.b64encode(stored_key).decode('ascii')
b64_server = base64.b64encode(server_key).decode('ascii')
print(f"SCRAM-SHA-256${iters}:{b64_salt}${b64_stored}:{b64_server}")
PY
)

echo "Generated SCRAM line for user '$USER':"
echo "\"$USER\" \"$SCRAM\""

if [ "$FORCE_APPLY" -eq 1 ]; then
  sudo cp -a "$USERLIST" "$USERLIST.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  sudo cp "$USERLIST" "$TMP" || true
  # replace or append
  if grep -q "^\"$USER\" " "$TMP"; then
    sudo sed -i "s/^\"$USER\" .*/\"$USER\" \"$SCRAM\"/" "$TMP"
  else
    printf "%s\n" "\"$USER\" \"$SCRAM\"" | sudo tee -a "$TMP" >/dev/null
  fi
  sudo mv "$TMP" "$USERLIST"
  echo "Applied. Reload PgBouncer required."
fi
