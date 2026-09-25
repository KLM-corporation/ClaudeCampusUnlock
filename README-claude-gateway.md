# Passerelle web privée pour Claude (Windows / Docker)

> Guide rapide pour la méthode Windows. Pour la documentation complète et la variante Termux / Android, consulte le [README principal](README.md).

Le script [install-claude-gateway.ps1](install-claude-gateway.ps1) configure, sur un PC Windows chez toi :

- un navigateur Firefox isolé par ami ;
- un profil et des cookies séparés pour chaque ami ;
- une authentification propre à chaque ami ;
- Caddy pour le HTTPS automatique ;
- aucun port Firefox exposé directement sur Internet.

## Utilisation

1. Copie [install-claude-gateway.ps1](install-claude-gateway.ps1) sur le PC Windows situé chez toi.
2. Ouvre **PowerShell en tant qu'administrateur**.
3. Si Docker Desktop n'est pas encore installé :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\install-claude-gateway.ps1 -InstallDocker
```

Docker Desktop peut demander un redémarrage de la machine. Après le redémarrage, démarre Docker Desktop puis relance :

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\install-claude-gateway.ps1
```

4. Le script demande le nombre d'amis, un identifiant court et un nom DNS public unique par ami.
5. Il génère les mots de passe de passerelle et les affiche une seule fois.
6. Il crée les fichiers de déploiement dans :

```text
%USERPROFILE%\claude-gateway
```

## Routeur et DynDNS

Le script ne modifie pas le routeur. Il faut :

- réserver une adresse IP locale fixe pour le PC Windows ;
- faire pointer chaque nom DNS vers l'adresse IP publique de la maison ;
- rediriger TCP 80 vers le port 80 du PC ;
- rediriger TCP 443 vers le port 443 du PC ;
- ne pas rediriger les ports 5800, 5900 ou 3389.

Caddy demandera automatiquement les certificats HTTPS une fois le DNS et le routeur correctement configurés.

Si le routeur est derrière un CGNAT, une redirection de ports classique ne marchera probablement pas. Dans ce cas, il faudra remplacer Caddy exposé directement par un tunnel sortant (par exemple Cloudflare Tunnel).

## Après installation

Tester l'état :

```powershell
cd "$env:USERPROFILE\claude-gateway"
docker compose ps
docker compose logs -f caddy
```

Mettre à jour :

```powershell
docker compose pull
docker compose up -d
```

Arrêter :

```powershell
docker compose down
```

## Sécurité

- Ne partage pas le fichier `.env` : il contient les mots de passe des passerelles.
- Chaque ami doit utiliser son propre compte Claude.
- Ne partage la passerelle qu'avec des personnes de confiance : leur navigation sortira par ton adresse IP.
- N'ouvre jamais directement RDP (`3389`) ou les ports Firefox (`5800`, `5900`) sur Internet.
- Les sessions sont séparées, mais l'administrateur du PC qui héberge Docker peut techniquement accéder aux fichiers persistants des conteneurs.
- Consulte [SECURITY.md](SECURITY.md) pour les règles de sécurité complètes.
