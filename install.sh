#!/bin/bash
#
# install.sh - installation de Carbonio CE mono-serveur sur RHEL 9, Rocky Linux 9 ou AlmaLinux 9
#
# Pré-requis : configure.sh, puis prep.sh check sans erreur (FQDN, /etc/hosts, DNS A et MX,
# locale, SELinux permissive, dépôts CRB + EPEL), et pare-feu en place (firewall.sh).
#
# Usage (root) :   bash install.sh
# Conseillé (survit à une coupure SSH) :
#   systemd-run --unit=carbonio-install bash $PWD/install.sh ; journalctl -fu carbonio-install
#
# Reprend l'ordre du script officiel Zextras pour RHEL 8 (non disponible pour RHEL 9) :
#   mesh configuré en mode non interactif, jeton Consul passé à pending-setups, bases
#   message-dispatcher / preview installées APRES le bootstrap des autres bases.
# Chaque étape réussie est notée dans $STATE_DIR : en cas d'erreur (elle est affichée), la corriger
# puis relancer le script, il reprend à l'étape en échec.
#
# Les secrets (PostgreSQL, Carbonio Mesh, admin) sont générés aléatoirement et écrits dans
# $SECRETS (root, 600). Ils ne sont jamais affichés : les reporter dans le coffre-fort puis
# supprimer le fichier.
#
set -euo pipefail

DIR=$(dirname "$(readlink -f "$0")")
CONF=${CARBONIO_CONF:-$DIR/carbonio.conf}
[ -s "$CONF" ] || { echo "$CONF absent : lancer d'abord bash configure.sh" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
PREP_SCRIPT=${PREP_SCRIPT-$DIR/prep.sh}    # contrôle des prérequis (PREP_SCRIPT= pour l'ignorer)
VIDEO_IP=${PUBLIC_IP:-$SERVER_IP}          # IP annoncée aux navigateurs par la visio (nat_1_1_mapping)
DKIM_SELECTOR=${DKIM_SELECTOR:-carbonio}   # sélecteur fixe : le nom DNS ne change pas d'une réinstallation à l'autre
LE_ENABLE=${LE_ENABLE:-yes}                # Let's Encrypt : 5 certificats identiques par semaine maximum
LE_EMAIL=${LE_EMAIL:-}

export HOME=/root   # absent sous systemd-run, gpg et su en ont besoin
STATE_DIR=/root/.carbonio-install
SECRETS=/root/carbonio-secrets.env
LOG=/root/carbonio-install-$(date +%Y%m%d-%H%M%S).log
DOMAIN=$MAIL_DOMAIN
PG=/usr/pgsql-16/bin
PGDATA=/var/lib/pgsql/16/data

[ "$(id -u)" -eq 0 ] || { echo "A lancer en root." >&2; exit 1; }
[ "$(hostname -f)" = "$FQDN" ] || { echo "hostname -f = $(hostname -f), attendu $FQDN : lancer prep.sh apply" >&2; exit 1; }
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
exec > >(tee -a "$LOG") 2>&1
trap 'echo; echo "!!! ECHEC à la ligne $LINENO (étape en cours : ${CUR_STEP:-?}). Journal : $LOG"; echo "Corriger puis relancer : les étapes déjà faites seront sautées."' ERR

# Exécute une étape une seule fois : step <id> <description> <fonction>
step() {
  CUR_STEP=$1
  if [ -e "$STATE_DIR/$1.done" ]; then echo "== [déjà fait] $2"; return; fi
  echo; echo "== $(date +%T) $2"
  "$3"
  touch "$STATE_DIR/$1.done"
}
as_zextras() { su - zextras -c "$*"; }
gen() { openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24; }

# ---------------------------------------------------------------- secrets
if [ ! -s "$SECRETS" ]; then
  umask 077
  printf 'DB_ADM_PWD=%s\nMESH_SECRET=%s\nADMIN_PWD=%s\n' "$(gen)" "$(gen)" "$(gen)" > "$SECRETS"
  umask 022
  echo "Secrets générés dans $SECRETS (non affichés)."
fi
# shellcheck disable=SC1090
. "$SECRETS"
[ -n "${DB_ADM_PWD:-}" ] && [ -n "${MESH_SECRET:-}" ] && [ -n "${ADMIN_PWD:-}" ] || { echo "$SECRETS incomplet" >&2; exit 1; }

# ---------------------------------------------------------------- étapes
s00_prereq() {
  [ -z "$PREP_SCRIPT" ] && { echo "contrôle ignoré"; return; }
  bash "$PREP_SCRIPT" check || { echo "Prérequis non remplis : voir ci-dessus." >&2; false; }
}

s01_postgres() {
  rpm -q pgdg-redhat-repo >/dev/null 2>&1 || dnf -y install https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  dnf -qy module disable postgresql
  dnf -y install postgresql16 postgresql16-server
  # Piège : un répertoire de données non vide (tentative précédente) fait échouer initdb
  if [ ! -s "$PGDATA/PG_VERSION" ]; then
    [ -z "$(ls -A "$PGDATA" 2>/dev/null)" ] || { echo "$PGDATA non vide sans PG_VERSION : nettoyer à la main" >&2; false; }
    "$PG/postgresql-16-setup" initdb
  fi
  systemctl enable --now postgresql-16
}

s02_postgres_conf() {
  local esc=${DB_ADM_PWD//\'/\'\'}
  su - postgres -c "psql -v ON_ERROR_STOP=1 -q" <<EOF
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'carbonio_adm') THEN
    CREATE ROLE carbonio_adm WITH LOGIN SUPERUSER ENCRYPTED PASSWORD '$esc';
  ELSE
    ALTER ROLE carbonio_adm WITH ENCRYPTED PASSWORD '$esc';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE carbonio_adm OWNER carbonio_adm'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'carbonio_adm')\gexec
ALTER SYSTEM SET listen_addresses TO '*';
ALTER SYSTEM SET max_connections = 500;
ALTER SYSTEM SET shared_buffers = 5000;
EOF
  # Authentification par mot de passe en local. Le "ident" par défaut de RHEL ferait échouer
  # les connexions TCP des composants (le script officiel RHEL fait la même correction).
  cp -p "$PGDATA/pg_hba.conf" "$PGDATA/pg_hba.conf.bak-carbonio"
  sed -i -E 's/^(host\s+all\s+all\s+\S+\s+)ident\s*$/\1scram-sha-256/' "$PGDATA/pg_hba.conf"
  # Pas de 0.0.0.0/0 comme dans la doc : seuls le serveur lui-même et son IP sont autorisés
  grep -qE "^host\s+all\s+all\s+${SERVER_IP//./\\.}/32\s" "$PGDATA/pg_hba.conf" || \
    echo "host    all             all             $SERVER_IP/32          scram-sha-256" >> "$PGDATA/pg_hba.conf"
  systemctl restart postgresql-16
  PGPASSWORD=$DB_ADM_PWD "$PG/psql" -h 127.0.0.1 -U carbonio_adm -d carbonio_adm -tAc 'select 1' | grep -q 1 && echo "connexion carbonio_adm OK"
}

s03_repo() {
  cat > /etc/yum.repos.d/zextras.repo <<'EOF'
[zextras]
name=zextras
baseurl=https://repo.zextras.io/release/rhel9
enabled=1
repo_gpgcheck=1
gpgcheck=0
gpgkey=https://repo.zextras.io/repomd.xml.key
EOF
  dnf -y makecache --repo zextras
  # outils utilisés par ce script : jq (jeton Mesh), needs-restarting (dnf-utils)
  dnf -y install jq dnf-utils
}

s04_upgrade() {
  dnf -y upgrade
  # un nouveau noyau impose un redémarrage AVANT d'installer Carbonio (sinon échecs aléatoires)
  if ! needs-restarting -r >/dev/null 2>&1; then
    echo; echo ">>> Redémarrage nécessaire (noyau ou bibliothèques système mis à jour)."
    echo ">>> Redémarrer (systemctl reboot), puis relancer ce script : il reprendra à l'étape suivante."
    touch "$STATE_DIR/s04.done"; exit 0
  fi
}

s05_packages() {
  # Le Postfix de RHEL occupe le port 25 et ferait boucler carbonio-postfix : désactivé, pas supprimé
  systemctl disable --now postfix 2>/dev/null || true
  dnf -y install service-discover-server
  # Liste du script officiel RHEL. message-dispatcher, preview-db et videoserver sont installés
  # plus tard, une fois les autres bases créées.
  dnf -y install carbonio-directory-server carbonio-proxy \
    carbonio-admin-console-ui carbonio-admin-login-ui carbonio-auth-ui \
    carbonio-calendars-ui carbonio-contacts-ui carbonio-login-ui \
    carbonio-mails-ui carbonio-search-ui carbonio-shell-ui \
    carbonio-files-ui carbonio-mta carbonio-appserver carbonio-user-management \
    carbonio-files-ce carbonio-files-public-folder-ui carbonio-files-db \
    carbonio-tasks-ce carbonio-tasks-db carbonio-tasks-ui \
    carbonio-storages-ce carbonio-preview-ce \
    carbonio-docs-connector-ce carbonio-docs-editor carbonio-prometheus \
    carbonio-message-broker \
    carbonio-ws-collaboration-ce carbonio-ws-collaboration-db carbonio-ws-collaboration-ui \
    carbonio-catalog carbonio-memcached
}

s06_bootstrap() {
  # configuration par défaut, non interactive (domaine = hostname -d)
  : > /root/carbonio-bootstrap.conf
  carbonio-bootstrap -c /root/carbonio-bootstrap.conf
  systemctl daemon-reload
}

mesh_token() {
  echo "$MESH_SECRET" | gpg --batch --yes --passphrase-fd 0 -qdo - /etc/zextras/service-discover/cluster-credentials.tar.gpg \
    | tar xOf - consul-acl-secret.json | jq -r .SecretID
}

s07_mesh() {
  if [ ! -s /etc/zextras/service-discover/cluster-credentials.tar.gpg ]; then
    # La commande exige un terminal, même avec --password : script lui en fournit un
    # Course connue : setup peut demander le jeton ACL avant l'élection du leader Consul
    # (environ 10 s, erreur "No cluster leader"). Il refuse ensuite de repartir ("already
    # performed") : sans cluster-credentials, rien n'est valide, on efface ce qu'il a créé
    # et on recommence un setup complet. --first-instance : serveur unique, et sans cette
    # option le 2e essai se croit serveur secondaire (trace laissée dans LDAP par le 1er).
    for i in 1 2 3 4 5 6; do
      script -qefc "service-discover setup '$SERVER_IP' --first-instance --password='$MESH_SECRET'" /dev/null || true
      [ -s /etc/zextras/service-discover/cluster-credentials.tar.gpg ] && break
      echo "service-discover setup : essai $i échoué, remise à zéro du Mesh"
      systemctl stop service-discover || true
      rm -f /etc/zextras/service-discover/main.json /etc/zextras/service-discover/config.json
      find /var/lib/service-discover -mindepth 1 -delete
      sleep 5
    done
    [ -s /etc/zextras/service-discover/cluster-credentials.tar.gpg ] || { echo "service-discover setup a échoué" >&2; false; }
  fi
  CONSUL_HTTP_TOKEN=$(mesh_token); export CONSUL_HTTP_TOKEN SETUP_CONSUL_TOKEN=$CONSUL_HTTP_TOKEN
  for i in $(seq 1 30); do consul members 2>/dev/null | grep -q alive && break; sleep 5; done
  consul members | grep -q alive || { echo "Carbonio Mesh (consul) ne répond pas" >&2; false; }
  pending-setups --execute-all
  systemctl restart carbonio-ws-collaboration-sidecar.service
}

# Crée une base Carbonio. Piège : si la base existe déjà, *-db-bootstrap sort sans écrire
# son mot de passe dans le Mesh. On ne lance donc le bootstrap que si la base n'existe pas.
db_bootstrap() {   # $1 = commande de bootstrap, $2 = nom de la base
  if su - postgres -c "psql -tAc \"select 1 from pg_database where datname='$2'\"" | grep -q 1; then
    echo "base $2 déjà présente : bootstrap sauté (si le composant ne démarre pas : DROP DATABASE/ROLE \"$2\" puis relancer)"
  else
    PGPASSWORD=$DB_ADM_PWD "$1" carbonio_adm 127.0.0.1
  fi
}

s08_databases() {
  CONSUL_HTTP_TOKEN=$(mesh_token); export CONSUL_HTTP_TOKEN SETUP_CONSUL_TOKEN=$CONSUL_HTTP_TOKEN
  db_bootstrap carbonio-files-db-bootstrap carbonio-files-db
  db_bootstrap carbonio-tasks-db-bootstrap carbonio-tasks-db
  db_bootstrap carbonio-ws-collaboration-db-bootstrap carbonio-ws-collaboration-db

  dnf -y install carbonio-message-dispatcher-db
  pending-setups --execute-all
  db_bootstrap carbonio-message-dispatcher-db-bootstrap carbonio-message-dispatcher-db

  dnf -y install carbonio-preview-db
  pending-setups --execute-all
  db_bootstrap carbonio-preview-db-bootstrap carbonio-preview-db
}

s09_late_components() {
  CONSUL_HTTP_TOKEN=$(mesh_token); export CONSUL_HTTP_TOKEN SETUP_CONSUL_TOKEN=$CONSUL_HTTP_TOKEN
  dnf -y install carbonio-message-dispatcher-ce carbonio-videoserver-ce
  pending-setups --execute-all
  # visio : IP annoncée aux navigateurs
  sed -i -E "s|^(\s*nat_1_1_mapping\s*=\s*).*|\1\"$VIDEO_IP\"|" /etc/janus/janus.jcfg
  grep -E '^\s*nat_1_1_mapping' /etc/janus/janus.jcfg
  systemctl enable carbonio-videoserver.service
  systemctl restart carbonio-videoserver.service
  # activé par le paquet mais jamais démarré
  systemctl enable --now carbonio-files-watches.service
}

s10_settings() {
  as_zextras "carbonio prov mcf zimbraDefaultDomainName $DOMAIN"
  as_zextras "carbonio prov md $DOMAIN zimbraVirtualHostname $DOMAIN"
  as_zextras "carbonio prov mc default carbonioFeatureWscEnabled TRUE"
  # mot de passe de l'administrateur (sans l'afficher)
  as_zextras "carbonio prov sp zextras@$DOMAIN '$ADMIN_PWD'" >/dev/null
  # compte GAL sync (carbonio-bootstrap ne le crée pas toujours)
  if ! as_zextras "carbonio prov -l gaa $DOMAIN" | grep -q '^galsync'; then
    as_zextras "zmgsautil createAccount -a galsync@$DOMAIN -n internal --domain $DOMAIN -t zimbra -s $FQDN"
  fi
}

s10b_dkim() {
  # Ne jamais afficher -q sans filtre : cette option sort la clé privée.
  local cmd=/opt/zextras/libexec/zmdkimkeyutil out
  out=$(as_zextras "$cmd -a -d $DOMAIN -s $DKIM_SELECTOR -b 2048") \
    || out=$(as_zextras "$cmd -u -d $DOMAIN -s $DKIM_SELECTOR -b 2048")
  echo; echo ">>> A publier dans le DNS (zone $DOMAIN ; une réinstallation change la valeur) :"
  echo "$out" | sed '/BEGIN.*PRIVATE KEY/,/END.*PRIVATE KEY/d'
}

s10c_letsencrypt() {
  # Le wrapper libexec/certbot rend 0 si son essai à blanc échoue : on appelle common/bin/certbot
  local cb=/opt/zextras/common/bin/certbot i
  local mail="--register-unsafely-without-email"
  [ -n "$LE_EMAIL" ] && mail="-m $LE_EMAIL"
  local args="certonly -n --agree-tos $mail --webroot -w /opt/zextras --key-type rsa --rsa-key-size 2048 --cert-name $FQDN -d $FQDN"
  install -m 755 "$DIR/carbonio-cert-deploy.sh" /usr/local/sbin/carbonio-cert-deploy.sh
  # Le port 80 est fermé par défaut : le proxy doit passer en mode redirect
  as_zextras "carbonio prov ms $FQDN zimbraReverseProxyMailMode redirect"
  install -d -o zextras -g zextras /opt/zextras/.well-known /opt/zextras/.well-known/acme-challenge
  systemctl restart carbonio-nginx.service
  for i in $(seq 1 24); do ss -ltn 'sport = :80' | grep -q LISTEN && break; sleep 5; done
  ss -ltn 'sport = :80' | grep -q LISTEN || { echo "Le port 80 n'écoute pas" >&2; false; }
  as_zextras "$cb $args --dry-run"
  as_zextras "$cb $args"
  /usr/local/sbin/carbonio-cert-deploy.sh
  # Renouvellement : minuteur désactivé par défaut, et rien ne redéploie le certificat
  mkdir -p /etc/systemd/system/carbonio-certbot.service.d
  printf '[Service]\nExecStartPost=+/usr/local/sbin/carbonio-cert-deploy.sh\n' \
    > /etc/systemd/system/carbonio-certbot.service.d/deploy.conf
  systemctl daemon-reload
  systemctl enable --now carbonio-certbot.timer
  as_zextras "$cb renew --dry-run"
}

s11_check() {
  echo "Unités Carbonio qui ne sont pas actives (hors services ponctuels) :"
  systemctl list-units 'carbonio-*' --all --no-legend --plain | awk '$3!="active"{print "  "$1, $3, $4}' \
    | grep -vE 'carbonio-(altermime-config|mailthreat-update|certbot)\.service' || echo "  aucune"
  pending-setups --list 2>/dev/null | tail -3 || true
  for u in "https://$FQDN/" "https://$FQDN:6071/"; do
    printf '  %s : %s\n' "$u" "$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "$u")"
  done
}

step s00 "0. Contrôle des prérequis"                   s00_prereq
step s01 "1. PostgreSQL 16"                             s01_postgres
step s02 "2. PostgreSQL : rôle carbonio_adm et accès"   s02_postgres_conf
step s03 "3. Dépôt Zextras"                             s03_repo
step s04 "4. Mise à jour du système"                    s04_upgrade
step s05 "5. Paquets Carbonio"                          s05_packages
step s06 "6. carbonio-bootstrap"                        s06_bootstrap
step s07 "7. Carbonio Mesh + pending-setups"            s07_mesh
step s08 "8. Bases de données Carbonio"                 s08_databases
step s09 "9. Message dispatcher et visio"               s09_late_components
step s10 "10. Réglages du domaine et compte admin"      s10_settings
step s10b "10b. Clé DKIM"                               s10b_dkim
if [ "$LE_ENABLE" = yes ]; then
  step s10c "10c. Certificat Let's Encrypt"             s10c_letsencrypt
fi
CUR_STEP=s11; echo; echo "== 11. Vérifications"; s11_check

trap - ERR
cat <<EOF

=====================================================================
Installation terminée. Journal : $LOG
Webmail          : https://$FQDN/
Administration   : https://$FQDN:6071/   (compte zextras@$DOMAIN)
Secrets (PostgreSQL, Mesh, admin) : $SECRETS
  -> les reporter dans le coffre-fort, puis : shred -u $SECRETS
=====================================================================
EOF
