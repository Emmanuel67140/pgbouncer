#!/usr/bin/env python3
# Génère une entrée SCRAM-SHA-256 utilisable dans userlist.txt
# Usage: ./02-scram-gen.py 'motdepasse' [iterations]
import sys, os, base64, hashlib, hmac, secrets
def gen_scram(pw, iters=4096):
    salt = secrets.token_bytes(16)
    salted = hashlib.pbkdf2_hmac('sha256', pw.encode('utf-8'), salt, iters)
    client_key = hmac.new(salted, b"Client Key", hashlib.sha256).digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted, b"Server Key", hashlib.sha256).digest()
    b64_salt = base64.b64encode(salt).decode('ascii')
    b64_stored = base64.b64encode(stored_key).decode('ascii')
    b64_server = base64.b64encode(server_key).decode('ascii')
    return f"SCRAM-SHA-256${iters}:{b64_salt}${b64_stored}:{b64_server}"

def main():
    if len(sys.argv) < 2:
        print("Usage: ./02-scram-gen.py 'motdepasse' [iterations]")
        sys.exit(2)
    pw = sys.argv[1]
    iters = int(sys.argv[2]) if len(sys.argv) >= 3 else 4096
    print(gen_scram(pw, iters))

if __name__ == '__main__':
    main()
