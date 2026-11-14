#!/bin/bash
#
# firewall.sh - pare-feu firewalld pour un serveur Carbonio CE mono-serveur (EL9)
#
# Principe :
#   zone « public » (interface de la route par défaut) : services mail/web et visio.
#   zone « carbonio-admin » (sources ADMIN_SRC de carbonio.conf) : SSH + console 6071.
#   Si ADMIN_SRC est vide : SSH reste ouvert à tous, la console 6071 est fermée
#   (y accéder par tunnel SSH : ssh -L 6071:localhost:6071 ...).
# Les autres interfaces ne sont pas modifiées.
#
# Usage (root) :
#   bash firewall.sh apply    # applique en RUNTIME, retour arrière auto après ROLLBACK_SECONDS
#   bash firewall.sh commit   # rend persistant
#   bash firewall.sh status   # affiche l'état
#
# Anti-verrouillage : "apply" ne touche pas à la configuration persistante. Tester depuis une
# NOUVELLE session SSH, puis "commit" avant la fin du délai. Sinon, rien à faire :
# la configuration précédente revient seule.
#
set -euo pipefail
DIR=$(dirname "$(readlink -f "$0")")
CONF=${CARBONIO_CONF:-$DIR/carbonio.conf}
[ "$(id -u)" -eq 0 ] || { echo "A lancer en root." >&2; exit 1; }
[ -s "$CONF" ] || { echo "$CONF absent : lancer d'abord bash configure.sh" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"
ROLLBACK_SECONDS=${ROLLBACK_SECONDS:-300}
OPEN_CHATS_5222=${OPEN_CHATS_5222:-no}   # 5222 : seulement pour des clients XMPP externes
read -r -a ADMIN <<< "${ADMIN_SRC:-}"
FW=firewall-cmd
ZA=carbonio-admin
ACTION=${1:-}
PUB_IF=$(ip -4 route show default | awk '{print $5; exit}')
[ -n "$PUB_IF" ] || { echo "Pas de route par défaut : interface publique introuvable." >&2; exit 1; }

if ! systemctl is-active --quiet firewalld; then
  [ "$ACTION" = apply ] || { echo "firewalld n'est pas actif (apply l'installe et le démarre)." >&2; exit 1; }
  rpm -q firewalld >/dev/null 2>&1 || dnf -y -q install firewalld
  systemctl enable --now firewalld   # zone public par défaut : SSH autorisé, pas de coupure
fi

MAIL_TCP=(25 465 587 993 80 443)
[ "${OPEN_IMAP_143:-yes}" = yes ] && MAIL_TCP+=(143)
[ "${OPEN_POP3:-no}" = yes ] && MAIL_TCP+=(110 995)
[ "$OPEN_CHATS_5222" = yes ] && MAIL_TCP+=(5222)

show_plan() {
  echo "Interface publique : $PUB_IF ($(ip -4 -o addr show "$PUB_IF" | awk '{print $4}' | head -1)) -> zone public"
  echo "  ports : ${MAIL_TCP[*]} + 20000-40000/udp (visio)$([ ${#ADMIN[@]} = 0 ] && echo ' + SSH')"
  if [ ${#ADMIN[@]} -gt 0 ]; then echo "Administration (SSH + 6071) depuis : ${ADMIN[*]}"
  else echo "ADMIN_SRC vide : SSH ouvert à tous, console 6071 fermée (tunnel SSH)"; fi
}

# La session SSH en cours doit rester autorisée
check_my_session() {
  local me=${SSH_CLIENT%% *}
  [ -z "$me" ] || [ ${#ADMIN[@]} = 0 ] && return 0
  python3 - "$me" "${ADMIN[@]}" <<'EOF' || { echo "Votre adresse $me n'est pas dans ADMIN_SRC : arrêt (vous seriez coupé)." >&2; exit 1; }
import sys, ipaddress
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(n, strict=False) for n in sys.argv[2:]) else 1)
EOF
}

reset_zone() {   # vide services, ports et sources d'une zone. $1 = zone, $2 = "" ou "--permanent"
  local z=$1 P=${2:-}
  for s in $($FW $P --zone="$z" --list-services); do $FW $P --zone="$z" --remove-service="$s" >/dev/null; done
  for p in $($FW $P --zone="$z" --list-ports); do $FW $P --zone="$z" --remove-port="$p" >/dev/null; done
  for s in $($FW $P --zone="$z" --list-sources); do $FW $P --zone="$z" --remove-source="$s" >/dev/null; done
}

rules() {   # $1 = "" ou "--permanent"
  local P=${1:-}
  # admin d'abord, pour ne jamais couper la session en cours
  reset_zone $ZA "$P"
  if [ ${#ADMIN[@]} -gt 0 ]; then
    for s in "${ADMIN[@]}"; do $FW $P --zone=$ZA --add-source="$s" >/dev/null; done
    $FW $P --zone=$ZA --add-service=ssh --add-port=6071/tcp >/dev/null
    # les admins utilisent aussi le webmail et les clients de messagerie
    for p in "${MAIL_TCP[@]}"; do $FW $P --zone=$ZA --add-port="${p}/tcp" >/dev/null; done
    $FW $P --zone=$ZA --add-port=20000-40000/udp >/dev/null
  fi
  reset_zone public "$P"
  for p in "${MAIL_TCP[@]}"; do $FW $P --zone=public --add-port="${p}/tcp" >/dev/null; done
  $FW $P --zone=public --add-port=20000-40000/udp >/dev/null
  [ ${#ADMIN[@]} = 0 ] && $FW $P --zone=public --add-service=ssh >/dev/null
  $FW $P --zone=public --add-service=dhcpv6-client >/dev/null 2>&1 || true
}

case "$ACTION" in
  apply)
    show_plan
    check_my_session
    $FW --permanent --get-zones | tr ' ' '\n' | grep -qx $ZA || $FW --permanent --new-zone=$ZA >/dev/null
    $FW --reload
    systemctl stop fw-rollback.timer 2>/dev/null || true
    systemd-run --quiet --unit=fw-rollback --on-active="$ROLLBACK_SECONDS" /usr/bin/firewall-cmd --reload
    echo "[i] Retour arrière automatique dans ${ROLLBACK_SECONDS}s (firewall-cmd --reload)."
    rules ""
    $FW --zone=public --change-interface="$PUB_IF" >/dev/null
    $FW --get-active-zones
    cat <<EOF

=====================================================================
Règles appliquées en RUNTIME uniquement.
1) Ouvrez une NOUVELLE session SSH et vérifiez l'accès.
2) Si tout est bon, avant ${ROLLBACK_SECONDS}s :   bash $0 commit
3) Sinon, ne faites rien : la configuration précédente revient seule.
=====================================================================
EOF
    ;;
  commit)
    systemctl stop fw-rollback.timer 2>/dev/null || true
    $FW --runtime-to-permanent
    c=$(nmcli -g GENERAL.CONNECTION dev show "$PUB_IF" 2>/dev/null || true)
    [ -n "$c" ] && nmcli con mod "$c" connection.zone public && echo "connexion '$c' ($PUB_IF) -> zone public"
    $FW --set-log-denied=unicast >/dev/null
    $FW --get-active-zones
    echo "Configuration persistante enregistrée (refus journalisés : journalctl -k | grep -i reject)."
    ;;
  status)
    show_plan
    $FW --get-active-zones
    for z in $ZA public; do echo; $FW --zone="$z" --list-all 2>/dev/null || true; done
    ;;
  *)
    echo "Usage : $0 apply|commit|status" >&2; exit 1 ;;
esac
