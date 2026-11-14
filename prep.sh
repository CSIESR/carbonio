#!/bin/bash
#
# prep.sh - préparation système et contrôle des prérequis avant l'installation
# de Carbonio CE mono-serveur sur RHEL 9, Rocky Linux 9 ou AlmaLinux 9.
#
# Usage (root) :
#   bash prep.sh check   # contrôle seul, ne modifie rien
#   bash prep.sh apply   # applique les réglages système, puis contrôle
#
# "apply" règle : dépôts CRB + EPEL, nom d'hôte, /etc/hosts, locale en_US.UTF-8,
# SELinux permissive, résolveurs DNS (si demandés), heure (chrony).
# "check" vérifie en plus : ressources, /opt, DNS (A, MX, PTR), port 25 sortant, restes
# d'une installation précédente. Relançable sans risque.
#
# Paramètres : carbonio.conf (créé par configure.sh).
#
set -uo pipefail
DIR=$(dirname "$(readlink -f "$0")")
CONF=${CARBONIO_CONF:-$DIR/carbonio.conf}
[ "$(id -u)" -eq 0 ] || { echo "A lancer en root." >&2; exit 1; }
[ -s "$CONF" ] || { echo "$CONF absent : lancer d'abord bash configure.sh" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
ACTION=${1:-}
case "$ACTION" in check|apply) ;; *) echo "Usage : $0 check|apply" >&2; exit 1 ;; esac

SHORT=${FQDN%%.*}
PUBLIC_IP=${PUBLIC_IP:-$SERVER_IP}
TIMEZONE=${TIMEZONE:-Europe/Paris}
. /etc/os-release
DISTRO=$ID   # rhel, rocky, almalinux
command -v dig >/dev/null || dnf -y -q install bind-utils >/dev/null
TS=$(date +%Y%m%d-%H%M%S)
ERR=0; WARN=0
ok()   { printf '  [OK]    %s\n' "$*"; }
ko()   { printf '  [ERREUR] %s\n' "$*"; ERR=$((ERR+1)); }
warn() { printf '  [ATTENTION] %s\n' "$*"; WARN=$((WARN+1)); }
step() { echo; echo "== $*"; }

if [ "$ACTION" = apply ]; then
  step "Réglages système"
  # Dépôts : CRB (CodeReady Builder) et EPEL
  if [ "$DISTRO" = rhel ]; then
    subscription-manager repos --enable "codeready-builder-for-rhel-9-$(arch)-rpms" >/dev/null && echo "  dépôt CodeReady Builder activé"
    rpm -q epel-release >/dev/null 2>&1 || dnf -y -q install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
  else
    rpm -q dnf-plugins-core >/dev/null 2>&1 || dnf -y -q install dnf-plugins-core
    dnf config-manager --set-enabled crb && echo "  dépôt crb activé"
    rpm -q epel-release >/dev/null 2>&1 || dnf -y -q install epel-release
  fi
  echo "  EPEL : $(rpm -q epel-release)"
  # Nom d'hôte
  hostnamectl set-hostname "$FQDN" && echo "  nom d'hôte : $FQDN"
  # /etc/hosts : localhost + FQDN, sans aucune entrée IPv6 (exigence Carbonio)
  cp -p /etc/hosts /etc/hosts.bak-$TS
  printf '127.0.0.1   localhost localhost.localdomain\n%s   %s %s\n' "$SERVER_IP" "$FQDN" "$SHORT" > /etc/hosts
  echo "  /etc/hosts réécrit (sauvegarde /etc/hosts.bak-$TS)"
  # Images cloud : cloud-init réécrit /etc/hosts et le nom d'hôte au démarrage, sauf si on l'en empêche
  if [ -d /etc/cloud/cloud.cfg.d ]; then
    printf 'manage_etc_hosts: false\npreserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-carbonio.cfg
    echo "  cloud-init : /etc/hosts et nom d'hôte préservés"
  fi
  # Résolveurs DNS imposés, sur la connexion NetworkManager de la route par défaut
  if [ -n "${DNS_SERVERS:-}" ]; then
    dev=$(ip -4 route show default | awk '{print $5; exit}')
    con=$(nmcli -g GENERAL.CONNECTION dev show "$dev" 2>/dev/null || true)
    if [ -n "$con" ]; then
      nmcli con mod "$con" ipv4.dns "$DNS_SERVERS" ipv4.ignore-auto-dns yes
      nmcli dev reapply "$dev" >/dev/null && echo "  résolveurs DNS ($con) : $DNS_SERVERS"
    else
      warn "connexion NetworkManager de $dev introuvable : résolveurs DNS non modifiés"
    fi
  fi
  # Locale en_US.UTF-8 (exigée par Carbonio)
  rpm -q glibc-langpack-en >/dev/null 2>&1 || dnf -y -q install glibc-langpack-en
  localectl set-locale LANG=en_US.UTF-8 && echo "  locale : en_US.UTF-8 (effective à la prochaine connexion)"
  # SELinux permissive (exigé par Carbonio sur EL9 : sinon les composants Java échouent sur execmem)
  if grep -q '^SELINUX=enforcing' /etc/selinux/config; then
    cp -p /etc/selinux/config /etc/selinux/config.bak-$TS
    sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
  fi
  setenforce 0 2>/dev/null || true
  echo "  SELinux : $(getenforce) (fichier : $(grep ^SELINUX= /etc/selinux/config))"
  # Heure : chrony actif (TLS, DKIM, journaux)
  rpm -q chrony >/dev/null 2>&1 || dnf -y -q install chrony
  if [ -n "${NTP_SERVER:-}" ] && ! grep -q "^server $NTP_SERVER " /etc/chrony.conf; then
    cp -p /etc/chrony.conf /etc/chrony.conf.bak-$TS
    # chrony refuse les commentaires en fin de ligne : commentaire sur sa propre ligne
    sed -i -E 's/^(pool|server) /#&/' /etc/chrony.conf
    printf '# NTP choisi dans carbonio.conf\nserver %s iburst\n' "$NTP_SERVER" >> /etc/chrony.conf
  fi
  systemctl enable chronyd >/dev/null 2>&1; systemctl restart chronyd; sleep 5; chronyc -a makestep >/dev/null
  timedatectl set-timezone "$TIMEZONE"
  echo "  chrony actif (${NTP_SERVER:-pool public}), fuseau $TIMEZONE"
  # fstab : point de montage du swap à "none" (et non /mnt)
  if grep -qE '^\S+\s+/mnt\s+swap\s' /etc/fstab; then
    cp -p /etc/fstab /etc/fstab.bak-$TS
    sed -i -E 's#^(\S+)\s+/mnt\s+swap\s#\1 none swap #' /etc/fstab
    echo "  fstab : swap monté sur none"
  fi
fi

step "Système"
case "$DISTRO" in
  rhel|rocky|almalinux) [ "${VERSION_ID%%.*}" = 9 ] && ok "$PRETTY_NAME" || ko "$PRETTY_NAME : version 9 requise" ;;
  *) ko "$PRETTY_NAME non pris en charge (RHEL, Rocky ou AlmaLinux 9)" ;;
esac
[ "$(arch)" = x86_64 ] && ok "architecture x86_64" || ko "architecture $(arch) : Carbonio n'est publié qu'en x86_64"
c=$(nproc); [ "$c" -ge 4 ] && ok "$c vCPU" || ko "$c vCPU (minimum 4)"
# une VM de 16 Go n'en annonce qu'environ 15,5 (mémoire réservée par le noyau) : seuil à 15 Gio
m=$(awk '/MemTotal/{printf "%.1f", $2/1024/1024}' /proc/meminfo); awk -v m="$m" 'BEGIN{exit !(m>=15)}' && ok "$m Gio de RAM" || ko "$m Gio de RAM (minimum 16 Go)"
r=$(df -BG --output=avail / | tail -1 | tr -dc 0-9); [ "$r" -ge 20 ] && ok "/ : $r Go libres" || ko "/ : $r Go libres (PostgreSQL et journaux sont sur /)"
if findmnt -no SOURCE /opt >/dev/null; then
  o=$(df -BG --output=avail /opt | tail -1 | tr -dc 0-9); ok "/opt monté séparément ($(findmnt -no SOURCE /opt)), $o Go libres"
else warn "/opt n'est pas un volume séparé (les boîtes aux lettres seront sur /)"; fi
[ "$(getenforce)" != Enforcing ] && grep -qE '^SELINUX=(permissive|disabled)' /etc/selinux/config && ok "SELinux $(getenforce)" || ko "SELinux doit être permissive (actuel : $(getenforce))"
localectl status | grep -q 'LANG=en_US.UTF-8' && ok "locale système en_US.UTF-8" || ko "locale système : $(localectl status | awk -F= '/LANG/{print $2}') (en_US.UTF-8 requise)"
chronyc -n sources 2>/dev/null | grep -q "^\^\*" && ok "heure synchronisée (NTP : $(chronyc -n sources | awk '/^\^\*/{print $2}'))" || warn "heure non synchronisée (chronyc sources : aucune source sélectionnée)"

step "Nom d'hôte et /etc/hosts"
[ "$(hostname -f)" = "$FQDN" ] && ok "hostname -f = $FQDN" || ko "hostname -f = $(hostname -f) (attendu $FQDN)"
[ "$(hostname -d)" = "$MAIL_DOMAIN" ] && ok "hostname -d = $MAIL_DOMAIN" || ko "hostname -d = $(hostname -d) (attendu $MAIL_DOMAIN : Carbonio crée son domaine à partir de lui)"
grep -qE "^${SERVER_IP//./\\.}\s+${FQDN//./\\.}(\s|$)" /etc/hosts && ok "/etc/hosts : $SERVER_IP $FQDN" || ko "/etc/hosts ne contient pas « $SERVER_IP $FQDN »"
grep -qE '^\s*[0-9a-fA-F]*:[0-9a-fA-F:]+\s' /etc/hosts && ko "/etc/hosts contient des entrées IPv6 (interdit par Carbonio)" || ok "aucune entrée IPv6 dans /etc/hosts"
ip -4 -o addr | grep -q " $SERVER_IP/" && ok "$SERVER_IP est portée par $(ip -4 -o addr | awk -v ip="$SERVER_IP" 'index($4, ip"/")==1{print $2}')" || ko "$SERVER_IP n'est portée par aucune interface"

step "DNS"
a=$(dig +short A "$FQDN" | tail -1)
[ "$a" = "$PUBLIC_IP" ] && ok "A $FQDN -> $a" || ko "A $FQDN -> ${a:-absent} (attendu $PUBLIC_IP)"
mx=$(dig +short MX "$MAIL_DOMAIN" | awk '{print $2}' | sed 's/\.$//')
echo "$mx" | grep -qx "$FQDN" && ok "MX $MAIL_DOMAIN -> $FQDN" || ko "MX $MAIL_DOMAIN -> ${mx:-absent} (attendu $FQDN ; carbonio-bootstrap s'arrête sinon)"
# le reverse peut être délégué par CNAME (RFC 2317) : on garde le nom final
ptr=$(dig +short -x "$PUBLIC_IP" | grep -v 'in-addr\.arpa\.$' | tail -1 | sed 's/\.$//')
[ "$ptr" = "$FQDN" ] && ok "PTR $PUBLIC_IP -> $ptr" || warn "PTR $PUBLIC_IP -> ${ptr:-absent} (attendu $FQDN : sans lui, le courrier sortant sera rejeté par Gmail/Microsoft)"
spf=$(dig +short TXT "$MAIL_DOMAIN" | tr -d '"' | grep -i '^v=spf1' | head -1)
[ -n "$spf" ] && ok "SPF : $spf" || warn "pas d'enregistrement SPF pour $MAIL_DOMAIN"

step "Dépôts et réseau sortant"
repos=$(dnf repolist --enabled 2>/dev/null | awk 'NR>1{print $1}')
if [ "$DISTRO" = rhel ]; then need="rhel-9-for-x86_64-baseos-rpms rhel-9-for-x86_64-appstream-rpms codeready-builder-for-rhel-9-x86_64-rpms epel"
else need="baseos appstream crb epel"; fi
for r in $need; do echo "$repos" | grep -qx "$r" && ok "dépôt $r" || ko "dépôt $r non activé (prep.sh apply l'active)"; done
echo "$repos" | grep -qx zextras && ok "dépôt zextras" || warn "dépôt zextras pas encore configuré (étape d'installation)"
echo "$repos" | grep -qx pgdg16 && ok "dépôt PostgreSQL 16" || warn "dépôt PostgreSQL pas encore configuré (étape d'installation)"
curl -s -o /dev/null -m 10 https://repo.zextras.io/release/rhel9/repodata/repomd.xml && ok "repo.zextras.io joignable" || ko "repo.zextras.io injoignable"
timeout 5 bash -c '</dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null && ok "port 25 sortant ouvert" || ko "port 25 sortant bloqué (à faire ouvrir par l'hébergeur)"

step "Restes d'une installation précédente"
left=0
for d in /opt/zextras /etc/zextras /var/lib/service-discover /etc/carbonio /var/lib/pgsql/16/data/base; do
  [ -e "$d" ] && { warn "$d existe déjà"; left=1; }
done
rpm -qa | grep -qE '^(carbonio|service-discover)' && { warn "des paquets Carbonio sont déjà installés"; left=1; }
[ $left = 0 ] && ok "système vierge"

echo
echo "Bilan : $ERR erreur(s), $WARN avertissement(s)."
[ $ERR = 0 ] && echo "Prérequis remplis : l'installation de Carbonio peut commencer." || echo "Corriger les erreurs avant d'installer Carbonio."
exit $ERR
