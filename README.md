# Carbonio CE sur RHEL 9 / Rocky Linux 9 / AlmaLinux 9

Scripts d'installation de [Carbonio CE](https://www.zextras.com/carbonio-community-edition/) (Zextras) en **mono-serveur** sur EL9. Zextras ne fournit pas de script d'installation pour EL9 : ces scripts reprennent l'ordre du script officiel RHEL 8 et corrigent les pièges rencontrés en pratique.

Testé avec Carbonio CE 26.9 sur RHEL 9.8. Rocky et Alma 9 sont binairement compatibles, mais l'installation complète n'y a pas encore été rejouée de bout en bout : retours bienvenus.

## Prérequis

- RHEL, Rocky Linux ou AlmaLinux **9**, x86_64, installation minimale fraîche.
- **4 vCPU, 16 Go de RAM**, 20 Go libres sur `/`, idéalement un volume séparé pour `/opt` (boîtes aux lettres).
- Une **adresse IPv4 publique** (directe ou par NAT), le **port 25 sortant ouvert** (certains hébergeurs le bloquent par défaut).
- La main sur le **DNS** du domaine (A, MX, TXT) et sur le **reverse** (PTR) de l'adresse publique.
- RHEL : système enregistré (`subscription-manager`).

Le nom du serveur doit être **dans** le domaine de messagerie (`mail.example.org` pour `@example.org`) : Carbonio crée son domaine à partir de `hostname -d`.

> **Le domaine reçoit déjà son courrier ailleurs** (Google Workspace, Microsoft 365…) ? L'installation exige que le MX pointe vers ce serveur, et changer le MX déplace toute la réception. Pour un essai, utilisez un **sous-domaine** (`essai.example.org`, serveur `mail.essai.example.org`).

## Marche à suivre

Toutes les commandes se lancent **en root sur le futur serveur**.

### 1. Récupérer les scripts

```bash
dnf -y install git
git clone https://github.com/CSIESR/carbonio.git
cd carbonio
```

### 2. Répondre aux questions

```bash
bash configure.sh
```

Le script demande, en proposant une valeur par défaut (Entrée pour l'accepter) :

| Question | Exemple |
|---|---|
| Domaine de messagerie | `example.org` |
| Nom complet du serveur | `mail.example.org` |
| Adresse IPv4 du serveur (sur son interface) | `203.0.113.25` |
| Adresse IPv4 publique (différente seulement derrière un NAT) | `203.0.113.25` |
| Résolveurs DNS à imposer (vide = inchangés) | `1.1.1.1 9.9.9.9` |
| Serveur NTP (vide = pool public) | |
| Fuseau horaire | `Europe/Paris` |
| Réseaux d'administration (SSH et console 6071) | `198.51.100.0/24` |
| Certificat Let's Encrypt, adresse d'avis | `o`, `admin@example.org` |
| Sélecteur DKIM | `mail2026` |
| IMAP 143, POP3 | `o`, `n` |

Les réponses sont écrites dans `carbonio.conf` (relancer `configure.sh` pour les modifier). Le script affiche ensuite **les enregistrements DNS à créer** et ce qui existe déjà.

### 3. Créer les enregistrements DNS

Dans la zone du domaine : **A** du serveur, **MX**, **SPF**, **DMARC** (valeurs affichées à l'étape 2). Chez l'hébergeur de l'adresse publique : le **reverse (PTR)** vers le nom du serveur. Sans MX vers le serveur, l'installation s'arrête ; sans PTR, Gmail et Microsoft rejettent le courrier sortant.

### 4. Préparer le système

```bash
bash prep.sh apply     # dépôts CRB + EPEL, nom d'hôte, /etc/hosts, locale, SELinux, heure, DNS
bash prep.sh check     # contrôle seul : à relancer jusqu'à « 0 erreur(s) »
```

Les avertissements sur les dépôts `zextras` et PostgreSQL sont normaux à ce stade (ils sont ajoutés par l'installation). Les erreurs DNS disparaissent quand les enregistrements de l'étape 3 sont visibles (quelques minutes à quelques heures selon le TTL).

### 5. Mettre en place le pare-feu

```bash
bash firewall.sh apply
```

Les règles sont appliquées **à titre provisoire** pendant 5 minutes. Ouvrir une **nouvelle** session SSH pour vérifier que l'accès fonctionne toujours, puis :

```bash
bash firewall.sh commit
```

Sans `commit`, l'ancienne configuration revient seule : impossible de rester enfermé dehors.

### 6. Installer Carbonio

```bash
systemd-run --unit=carbonio-install bash "$PWD/install.sh"
journalctl -fu carbonio-install      # suivre l'avancement (Ctrl+C n'arrête pas l'installation)
```

`systemd-run` évite qu'une coupure SSH n'interrompe l'installation. Durée : 15 à 20 minutes.

- **Arrêt à l'étape 4** avec « Redémarrage nécessaire » : la mise à jour a installé un nouveau noyau. `systemctl reboot`, puis relancer la même commande `systemd-run` (avec un autre nom d'unité, par ex. `--unit=carbonio-install2`).
- **Erreur** : le message indique l'étape et le journal (`/root/carbonio-install-*.log`). Corriger, puis relancer : les étapes déjà faites sont sautées.

### 7. Finaliser

En fin d'installation, le journal affiche :

- l'adresse du **webmail** `https://<serveur>/` et de l'**administration** `https://<serveur>:6071/` (compte `zextras@<domaine>`, accessible seulement depuis les réseaux d'administration) ;
- l'emplacement des **mots de passe** générés : `/root/carbonio-secrets.env`. Les ranger dans un coffre-fort, puis `shred -u /root/carbonio-secrets.env` ;
- l'enregistrement **DKIM** à publier : `<sélecteur>._domainkey.<domaine>` de type TXT.

### 8. Vérifier

1. Se connecter au webmail avec `zextras@<domaine>`, créer un compte utilisateur depuis la console d'administration.
2. Envoyer un message vers une adresse Gmail : dans « Afficher l'original », lire `SPF: PASS`, `DKIM: PASS`, `DMARC: PASS`.
3. Répondre depuis Gmail et vérifier la réception.
4. Redémarrer le serveur (`systemctl reboot`) et vérifier que tout revient : `systemctl list-units 'carbonio-*' --state=failed` doit être vide (compter 2 à 3 minutes).

## Fichiers

| Fichier | Rôle |
|---|---|
| `configure.sh` | Questions, écriture de `carbonio.conf`, enregistrements DNS à créer, état du DNS |
| `prep.sh check\|apply` | Préparation du système et contrôle des prérequis |
| `firewall.sh apply\|commit\|status` | firewalld : services mail/web publics, SSH et console 6071 limités aux réseaux d'admin |
| `install.sh` | Installation de Carbonio, par étapes reprenables |
| `carbonio-cert-deploy.sh` | Déploiement du certificat Let's Encrypt dans Carbonio, à chaque renouvellement |
| `outils/fw-ports.sh` | Affiche les ports ouverts par zone firewalld |

`carbonio.conf` peut aussi être écrit à la main (voir `carbonio.conf.exemple`) pour une installation sans questions.

## Pièges traités par les scripts

- **SELinux** doit être *permissive* (les composants Java échouent sinon) ; **locale** `en_US.UTF-8` obligatoire ; **aucune ligne IPv6** dans `/etc/hosts`.
- Le **Postfix système** occupe le port 25 : désactivé (pas supprimé).
- `service-discover setup` exige un terminal, même avec `--password` : lancé via `script`.
- **Course au démarrage du Mesh** (« No cluster leader ») : le setup est remis à zéro et relancé, avec `--first-instance`.
- Les bases `*-db-bootstrap` ne doivent être lancées que si la base n'existe pas, sinon le mot de passe n'est pas enregistré dans le Mesh.
- `carbonio-files-watches` est activé mais jamais démarré.
- **Let's Encrypt** : le port 80 est fermé par défaut (passage en mode `redirect`), la chaîne n'inclut pas la racine exigée par `zmcertmgr`, et le minuteur de renouvellement est désactivé et ne redéploie rien : corrigé par `carbonio-cert-deploy.sh` et un *drop-in* systemd. Limite : 5 certificats identiques par semaine (attention aux réinstallations répétées : `LE_ENABLE=no`).
- **DKIM** : `zmdkimkeyutil -q` affiche la clé **privée** ; le script filtre sa sortie.
- **Visio** : l'adresse publique est déclarée à Janus (`nat_1_1_mapping`), indispensable derrière un NAT.
- **Images cloud** : cloud-init est empêché de réécrire `/etc/hosts` et le nom d'hôte au redémarrage.

## Après l'installation

- Tester l'envoi et la réception vers Gmail / Microsoft 365, et lire dans l'en-tête `dkim=pass`, `spf=pass`, `dmarc=pass`.
- Durcir DMARC (`p=quarantine`) une fois les rapports propres.
- Un réseau avec DNS dynamique (DDNS) renomme parfois la machine à partir de son nom d'hôte : fixer `ipv4.dhcp-hostname` dans NetworkManager si nécessaire.

## Licence

MIT. Aucune garantie : à tester d'abord sur une machine jetable.
