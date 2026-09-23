# Claude Gateway

Deux méthodes d’accès à un navigateur distant qui sort sur une connexion Internet contrôlée par l’administrateur :

1. **Windows + Docker Desktop + Caddy** : adapté à un PC Windows toujours allumé, avec un nom DNS public et une redirection HTTPS.
2. **Android + Termux** : solution expérimentale utilisant Chromium dans Debian/proot-distro, noVNC et un tunnel HTTPS temporaire.

Le navigateur s’exécute sur la machine relais. L’utilisateur distant n’a besoin que d’un navigateur web.

> **Important :** ce projet ne doit pas être déployé comme proxy ouvert. Il doit rester protégé par authentification, HTTPS et un accès limité à des personnes de confiance.

## Avertissement et sécurité

- Vérifie la législation locale, les règles de ton fournisseur d’accès et les conditions d’utilisation des services utilisés.
- Chaque utilisateur devrait utiliser son **propre compte Claude**. Ne partage jamais un mot de passe, cookie, session ou token Claude.
- Ne commite jamais de mot de passe, clé privée, token GitHub, fichier `.env`, cookie ou adresse personnelle.
- Un utilisateur distant peut faire sortir du trafic par l’adresse IP de la maison ou du téléphone. N’accorde l’accès qu’à des personnes de confiance.
- N’expose jamais directement les ports RDP `3389`, VNC `5900` ou les ports internes Firefox `5800`.
- L’option Web Terminal doit rester désactivée. Le gestionnaire de fichiers doit rester désactivé sauf nécessité.
- Les sessions persistantes peuvent contenir des cookies et données de navigation. L’administrateur de la machine hôte peut techniquement y accéder.

## Méthode 1 — Windows, Docker et Caddy

### Prérequis

- Windows 10/11 64 bits ;
- virtualisation matérielle activée ;
- WSL2 et Docker Desktop avec le moteur Linux ;
- un PC qui peut rester allumé ;
- un nom DNS public qui pointe vers l’adresse IP de la maison ;
- accès au routeur pour configurer NAT/PAT.

### Installation

Copie `install-claude-gateway.ps1` sur le PC Windows, puis ouvre PowerShell.

Si Docker Desktop n’est pas encore installé :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\install-claude-gateway.ps1 -InstallDocker
```

Après installation et démarrage de Docker Desktop, ou si Docker était déjà installé :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\install-claude-gateway.ps1
```

Le script demande un identifiant et un hostname public par session. Il génère les mots de passe des passerelles et crée les fichiers dans :

```text
%USERPROFILE%\claude-gateway
```

Vérifier l’état :

```powershell
cd "$env:USERPROFILE\claude-gateway"
docker compose ps
docker compose logs -f caddy
```

### Routeur et DNS

Réserve une adresse IP locale fixe pour le PC Windows, puis redirige uniquement :

```text
TCP 80  -> PC Windows : 80
TCP 443 -> PC Windows : 443
```

Le nom DNS doit être le nom complet configuré chez le fournisseur DDNS. Vérifie-le avec :

```powershell
Resolve-DnsName ton-hote.example.net -Server 1.1.1.1
```

Teste l’URL depuis un réseau extérieur, par exemple la 4G, et non uniquement depuis le Wi-Fi de la maison :

```text
https://ton-hote.example.net
```

### Presse-papier et fichiers

Le script désactive volontairement le presse-papier et le gestionnaire de fichiers par défaut.

Pour le presse-papier, dans le `compose.yml` généré, remplacer :

```yaml
WEB_HOST_CLIPBOARD_SYNC: "0"
```

par :

```yaml
WEB_HOST_CLIPBOARD_SYNC: "1"
```

Puis recréer les conteneurs :

```powershell
cd "$env:USERPROFILE\claude-gateway"
docker compose up -d --force-recreate
```

Le navigateur utilisé pour accéder à l’interface doit autoriser le presse-papier sur le domaine HTTPS.

Pour des transferts de fichiers ponctuels, le gestionnaire peut être activé avec prudence :

```yaml
WEB_FILE_MANAGER: "1"
WEB_FILE_MANAGER_ALLOWED_PATHS: "/config"
```

Garde toujours :

```yaml
WEB_TERMINAL: "0"
```

## Méthode 2 — Android et Termux

Cette méthode est expérimentale et vise une seule session Chromium partagée.

### Limitations

- une seule session de navigateur partagée ;
- forte consommation de batterie, mémoire et données mobiles ;
- Termux doit rester actif et exclu de l’optimisation batterie ;
- le Quick Tunnel donne une URL temporaire qui change après redémarrage ;
- le téléphone est généralement derrière un CGNAT, donc le DDNS du routeur n’est pas utilisé.

### Installation

Installer Termux depuis une source fiable, puis copier `termux-browser-gateway.sh` dans le dossier personnel de Termux :

```bash
chmod 700 "$HOME/termux-browser-gateway.sh"
./termux-browser-gateway.sh install
```

Démarrer :

```bash
termux-wake-lock
./termux-browser-gateway.sh start
```

Le terminal affiche une URL `trycloudflare.com`. L’utilisateur distant ouvre cette URL, puis si nécessaire :

```text
/vnc.html?autoconnect=1
```

Arrêter :

```bash
./termux-browser-gateway.sh stop
termux-wake-unlock
```

Le mot de passe protège l’interface noVNC. Ne partage pas l’URL et le mot de passe publiquement.

## Dépannage

### Docker Desktop reste bloqué

Vérifier :

```powershell
wsl --status
wsl -l -v
docker info
```

Si `docker info` ne répond pas, Docker Desktop ou son moteur Linux n’est pas démarré. Vérifie également la virtualisation matérielle et les fonctionnalités WSL2.

### Le DNS ne répond pas

```powershell
Resolve-DnsName ton-hote.example.net -Server 1.1.1.1
ipconfig /flushdns
```

Vérifie que l’adresse retournée correspond à l’adresse IP publique actuelle.

### Logs Windows

```powershell
cd "$env:USERPROFILE\claude-gateway"
docker compose logs --tail 100 caddy
docker compose logs --tail 100 gabi-firefox
```

### Logs Termux

```bash
proot-distro login debian -- bash -lc 'cat /root/claude-browser-logs/*.log'
```

## Publication sur GitHub

Le dépôt ne doit contenir aucun secret. Depuis une machine avec GitHub CLI authentifié :

```bash
gh auth login
gh repo create claude-gateway --public --source=. --remote=origin --push
```

Sinon, crée un dépôt vide sur GitHub puis :

```bash
git branch -M main
git remote add origin https://github.com/UTILISATEUR/claude-gateway.git
git push -u origin main
```

N’insère jamais un token dans une URL Git et ne partage jamais un token dans une conversation.
