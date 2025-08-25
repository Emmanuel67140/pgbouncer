# PgBouncer helper package (fourni par assistant)

Contenu du package:
- 01-pgbouncer-update.sh : met à jour /srv/pgbouncer/userlist.txt en MD5 pour admin + application, reload PgBouncer
- 02-scram-gen.py       : génère une entrée SCRAM-SHA-256 pour insertion manuelle
- 03-diagnostics.sh     : lance des tests directs et via PgBouncer, vérifie logs
- 04-scram-update.sh    : script safe pour générer (et optionnellement appliquer) une entrée SCRAM pour l'utilisateur applicatif
- docker-compose.sample.yml : exemple pour déployer PgBouncer (lecture de /srv/pgbouncer)
- userlist.sample.txt   : exemple de fichier userlist

IMPORTANT - sécurité
- Ce package contient des mots de passe en clair car fournis lors de la demande.
  Veille à protéger l'accès au zip et supprime les mots de passe du code si partagé.

Utilisation recommandée :
1. Copier/extraire sur la machine de déploy :
   sudo unzip pgbouncer_package.zip -d /home/deploy/pgbouncer_package
2. Rendre exécutables :
   cd /home/deploy/pgbouncer_package
   sudo chmod +x 01-pgbouncer-update.sh 03-diagnostics.sh 04-scram-update.sh 02-scram-gen.py

3. Lancer diagnostics et coller la sortie ici si tu veux que je l'analyse :
   sudo ./03-diagnostics.sh | tee diagnostics.log

4a. Si diagnostics montre que la connexion directe au backend fonctionne avec le mot de passe,
   et que PgBouncer attend MD5: utiliser 01-pgbouncer-update.sh (il écrit MD5 dans userlist.txt et RELOAD)

4b. Si tu veux utiliser SCRAM (nécessite que le backend accepte SCRAM), génère la ligne :
   ./02-scram-gen.py 'ercsEE376' 4096
   puis ajoute manuellement dans /srv/pgbouncer/userlist.txt ou utilise ./04-scram-update.sh --apply

5. Après update, vérifier logs et tests :
   sudo ./03-diagnostics.sh

Si tu veux que j'intègre d'autres modifications (ex: forcer écriture même si test échoue,
ou automatiser push sur le serveur distant), dis-moi exactement ce que tu veux automatiser.
