#!/bin/bash
# fw_ports.sh - pour chaque zone firewalld active : interfaces, sources, services (avec leurs ports),
# ports et règles riches. Lecture seule. Usage (root) : bash fw_ports.sh
F=firewall-cmd
for z in $($F --get-active-zones | grep -v '^\s'); do
  printf '\n== Zone %s  (cible : %s)\n' "$z" "$($F --permanent --zone="$z" --get-target)"
  printf '   %-24s %s\n' "interfaces" "$($F --zone="$z" --list-interfaces)" "sources" "$($F --zone="$z" --list-sources)"
  n=0
  for s in $($F --zone="$z" --list-services); do
    printf '   %-24s %s\n' "service $s" "$($F --info-service="$s" | awk -F': ' '/^ +ports:/{print $2}')"; n=1
  done
  p=$($F --zone="$z" --list-ports); [ -n "$p" ] && { printf '   %-24s %s\n' "ports" "$p"; n=1; }
  $F --zone="$z" --list-rich-rules | sed '/^$/d; s/^/   règle : /'
  [ $n = 0 ] && echo "   (aucun port ouvert)"
done
echo
