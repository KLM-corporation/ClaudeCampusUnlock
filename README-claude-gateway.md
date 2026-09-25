# Passerelle web privee pour Claude

Le script `install-claude-gateway.ps1` configure, sur un PC Windows chez toi :

- un navigateur Firefox isole par ami ;
- un profil et des cookies separes pour chaque ami ;
- une authentification par ami ;
- Caddy pour le HTTPS ;
- aucun port Firefox expose directement sur Internet.

## Utilisation

1. Copie `install-claude-gateway.ps1` sur le PC Windows situe chez toi.
2. Ouvre PowerShell en administrateur.
3. Si Docker Desktop n'est pas encore installe :

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-claude-gateway.ps1 -InstallDocker
```

Docker Desktop peut demander un redemarrage. Apres le redemarrage, demarre Docker Desktop puis relance :

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\install-claude-gateway.ps1
```

4. Le script demande le nombre d'amis, un identifiant court et un nom DNS public unique par ami.
5. Il genere les mots de passe de passerelle et les affiche une seule fois.
6. Il cree les fichiers dans :

```text
%USERPROFILE%\claude-gateway
```

## Routeur et DynDNS

Le script ne modifie pas le routeur. Il faut :

- reserver une adresse IP locale fixe pour le PC Windows ;
- faire pointer chaque nom DNS vers l'adresse IP publique de la maison ;
- rediriger TCP 80 vers le port 80 du PC ;
- rediriger TCP 443 vers le port 443 du PC ;
- ne pas rediriger les ports 5800, 5900 ou 3389.

Caddy demandera automatiquement les certificats HTTPS une fois le DNS et le routeur correctement configures.

Si le routeur est derriere un CGNAT, une redirection de ports classique ne marchera probablement pas. Dans ce cas, il faudra remplacer Caddy expose directement par un tunnel sortant.

## Apres installation

Tester l'etat :

```powershell
cd "$env:USERPROFILE\claude-gateway"
docker compose ps
docker compose logs -f caddy
```

Mettre a jour :

```powershell
docker compose pull
docker compose up -d
```

Arreter :

```powershell
docker compose down
```

## Securite

- Ne partage pas le fichier `.env` : il contient les mots de passe des passerelles.
- Chaque ami doit utiliser son propre compte Claude.
- Ne partage la passerelle qu'avec des personnes de confiance : leur navigation sortira par ton adresse IP.
- N'ouvre jamais directement RDP (`3389`) ou les ports Firefox (`5800`, `5900`) sur Internet.
- Les sessions sont separees, mais l'administrateur du PC qui heberge Docker peut techniquement acceder aux fichiers persistants des conteneurs.
