#!/bin/bash
#
# configure.sh - questions sur votre installation, puis écriture de carbonio.conf
#
# Usage (root, sur le futur serveur) :   bash configure.sh
#
# Les autres scripts (prep.sh, firewall.sh, install.sh) lisent tous carbonio.conf.
# Relançable : les réponses précédentes sont proposées par défaut.
# Affiche à la fin les enregistrements DNS à créer et vérifie ceux qui existent déjà.
#
set -uo pipefail
DIR=$(dirname "$(readlink -f "$0")")
CONF=${CARBONIO_CONF:-$DIR/carbonio.conf}
[ "$(id -u)" -eq 0 ] || { echo "A lancer en root." >&2; exit 1; }
command -v dig >/dev/null || dnf -y -q install bind-utils >/dev/null

# shellcheck disable=SC1090
[ -s "$CONF" ] && . "$CONF"

ask() {   # ask VAR "question" "défaut"
  local v
  read -r -p "$2${3:+ [$3]} : " v
  printf -v "$1" '%s' "${v:-$3}"
}
yesno() { case "$1" in y|Y|o|O|oui|yes) echo yes ;; *) echo no ;; esac; }
is_ip() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

echo "Configuration de l'installation Carbonio CE (RHEL 9 / Rocky 9 / Alma 9)."
echo "Entrée = valeur proposée entre crochets."
echo

# --- domaine et nom du serveur
while :; do
  ask MAIL_DOMAIN "Domaine de messagerie (adresses en @domaine)" "${MAIL_DOMAIN:-}"
  [[ $MAIL_DOMAIN =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && break
  echo "  -> nom de domaine invalide (minuscules, ex. example.org)"
done
while :; do
  ask FQDN "Nom complet du serveur" "${FQDN:-mail.$MAIL_DOMAIN}"
  # Carbonio crée son domaine à partir de « hostname -d » : le serveur doit être DANS le domaine
  [[ $FQDN == *."$MAIL_DOMAIN" ]] && break
  echo "  -> le nom du serveur doit se terminer par .$MAIL_DOMAIN (ex. mail.$MAIL_DOMAIN)"
done

# --- adresses
det_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") print $(i+1)}')
while :; do
  ask SERVER_IP "Adresse IPv4 du serveur (portée par son interface)" "${SERVER_IP:-$det_ip}"
  is_ip "$SERVER_IP" && ip -4 -o addr | grep -q " $SERVER_IP/" && break
  echo "  -> $SERVER_IP n'est portée par aucune interface de ce serveur"
done
dns_a=$(dig +short A "$FQDN" | tail -1)
# adresse privée (RFC 1918) = serveur derrière un NAT : l'adresse publique est à fournir
if [[ $SERVER_IP =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.) ]]; then
  echo "  $SERVER_IP est une adresse privée : le serveur est derrière un NAT."
  def_pub=""
else def_pub=$SERVER_IP; fi
[ -n "$dns_a" ] && echo "  (le DNS donne aujourd'hui $FQDN -> $dns_a)"
while :; do
  ask PUBLIC_IP "Adresse IPv4 publique du serveur (sera le A de $FQDN)" "${PUBLIC_IP:-$def_pub}"
  is_ip "$PUBLIC_IP" && break
done

# --- DNS, heure
cur_dns=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf | sed 's/ $//')
echo
echo "Résolveurs DNS actuels : ${cur_dns:-aucun}"
ask DNS_SERVERS "Résolveurs DNS à imposer (séparés par des espaces, vide = garder les actuels)" "${DNS_SERVERS:-}"
ask NTP_SERVER "Serveur NTP (vide = pool public de la distribution)" "${NTP_SERVER:-}"
ask TIMEZONE "Fuseau horaire" "${TIMEZONE:-Europe/Paris}"
timedatectl list-timezones 2>/dev/null | grep -qx "$TIMEZONE" || echo "  -> attention : fuseau $TIMEZONE inconnu"

# --- accès d'administration
echo
echo "Réseaux autorisés pour SSH et la console d'administration (port 6071)."
echo "  Exemple : 203.0.113.10/32 198.51.100.0/24. Vide = SSH ouvert à tous, console fermée."
[ -n "${SSH_CLIENT:-}" ] && echo "  (votre session SSH actuelle vient de ${SSH_CLIENT%% *})"
ask ADMIN_SRC "Réseaux d'administration" "${ADMIN_SRC:-}"

# --- options
echo
ask _le "Certificat Let's Encrypt pour $FQDN (o/n)" "$([ "${LE_ENABLE:-yes}" = yes ] && echo o || echo n)"
LE_ENABLE=$(yesno "$_le")
if [ "$LE_ENABLE" = yes ]; then
  ask LE_EMAIL "Adresse pour les avis Let's Encrypt (vide = aucune)" "${LE_EMAIL:-}"
else LE_EMAIL=""; fi
ask DKIM_SELECTOR "Sélecteur DKIM" "${DKIM_SELECTOR:-${FQDN%%.*}$(date +%Y)}"
ask _143 "Ouvrir IMAP 143 (STARTTLS) en plus de 993 (o/n)" "$([ "${OPEN_IMAP_143:-yes}" = yes ] && echo o || echo n)"
OPEN_IMAP_143=$(yesno "$_143")
ask _pop "Ouvrir POP3 (110/995) (o/n)" "$([ "${OPEN_POP3:-no}" = yes ] && echo o || echo n)"
OPEN_POP3=$(yesno "$_pop")

# --- écriture
umask 077
{
  echo "# carbonio.conf - écrit par configure.sh le $(date '+%F %T'). Modifiable à la main."
  for v in MAIL_DOMAIN FQDN SERVER_IP PUBLIC_IP DNS_SERVERS NTP_SERVER TIMEZONE ADMIN_SRC \
           LE_ENABLE LE_EMAIL DKIM_SELECTOR OPEN_IMAP_143 OPEN_POP3; do
    printf '%s=%q\n' "$v" "${!v}"
  done
} > "$CONF"
echo; echo "Configuration écrite dans $CONF"

# --- DNS à créer et état actuel
cat <<EOF

=====================================================================
Enregistrements DNS à créer AVANT l'installation (zone $MAIL_DOMAIN) :

$(printf '  %-28s %-6s %s\n' "$FQDN." A "$PUBLIC_IP" "$MAIL_DOMAIN." "MX" "10 $FQDN." \
   "$MAIL_DOMAIN." TXT '"v=spf1 mx -all"' "_dmarc.$MAIL_DOMAIN." TXT "\"v=DMARC1; p=none; rua=mailto:postmaster@$MAIL_DOMAIN\"")

Chez l'hébergeur ou le fournisseur de l'adresse $PUBLIC_IP :
  reverse (PTR) $PUBLIC_IP -> $FQDN

La clé DKIM ($DKIM_SELECTOR._domainkey) est affichée à la fin de install.sh.
=====================================================================
EOF

echo "État actuel :"
a=$(dig +short A "$FQDN" | tail -1)
[ "$a" = "$PUBLIC_IP" ] && echo "  [OK] A $FQDN" || echo "  [A FAIRE] A $FQDN -> ${a:-absent} (attendu $PUBLIC_IP)"
mx=$(dig +short MX "$MAIL_DOMAIN" | awk '{print $2}' | sed 's/\.$//' | tr '\n' ' ')
if echo " $mx " | grep -q " $FQDN "; then echo "  [OK] MX $MAIL_DOMAIN"
elif [ -n "$mx" ]; then
  echo "  [ATTENTION] MX $MAIL_DOMAIN -> $mx"
  echo "     Le domaine reçoit déjà son courrier ailleurs. Changer le MX déplace TOUTE la réception"
  echo "     vers ce serveur. Pour un essai, utilisez plutôt un sous-domaine (ex. essai.$MAIL_DOMAIN)."
else echo "  [A FAIRE] MX $MAIL_DOMAIN -> absent"; fi
ptr=$(dig +short -x "$PUBLIC_IP" | grep -v 'in-addr\.arpa\.$' | tail -1 | sed 's/\.$//')
[ "$ptr" = "$FQDN" ] && echo "  [OK] PTR $PUBLIC_IP" || echo "  [A FAIRE] PTR $PUBLIC_IP -> ${ptr:-absent}"
echo
echo "Suite : bash prep.sh apply"
