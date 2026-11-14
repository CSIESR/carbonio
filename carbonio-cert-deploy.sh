#!/bin/bash
# carbonio-cert-deploy.sh - déploie le certificat Let's Encrypt dans Carbonio.
# Appelé après chaque passage de carbonio-certbot.service (deux fois par jour) : ne fait
# rien si le certificat n'a pas changé, pour éviter de redémarrer les services pour rien.
set -euo pipefail
FQDN=$(hostname -f)
LIVE=/opt/zextras/common/certbot/etc/letsencrypt/live/$FQDN
STAMP=/var/lib/carbonio-cert-deploy.sha256
COMM=/opt/zextras/ssl/carbonio/commercial
BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

NEW=$(sha256sum "$LIVE/cert.pem" | cut -d' ' -f1)
[ "$NEW" = "$(cat "$STAMP" 2>/dev/null || true)" ] && exit 0

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
cp "$LIVE/cert.pem" "$WORK/cert.pem"
# Le fullchain de Let's Encrypt n'a pas la racine, que zmcertmgr exige : prise dans le magasin système
{ cat "$LIVE/chain.pem"; awk '/^# ISRG Root X1$/{f=1} f; f&&/END CERTIFICATE/{exit}' "$BUNDLE"; } > "$WORK/chain.pem"
grep -q 'BEGIN CERTIFICATE' "$WORK/chain.pem"
install -o zextras -g zextras -m 640 "$LIVE/privkey.pem" "$COMM/commercial.key"
chown -R zextras:zextras "$WORK"
su - zextras -c "zmcertmgr verifycrt comm $COMM/commercial.key $WORK/cert.pem $WORK/chain.pem"
su - zextras -c "zmcertmgr deploycrt comm $WORK/cert.pem $WORK/chain.pem"
systemctl restart carbonio-openldap.service
systemctl restart carbonio-postfix.service carbonio-nginx.service
echo "$NEW" > "$STAMP"
echo "Certificat déployé pour $FQDN."
