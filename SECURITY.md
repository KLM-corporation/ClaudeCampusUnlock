# Sécurité

Ce document décrit ce que la passerelle protège, ce qu'elle ne protège pas, et ce que vous devez faire de votre côté. Chaque point a été vérifié en exécutant la configuration générée (voir `tests/`).

## Ce qui est protégé

- **Zéro mot de passe en clair** : `users.json` ne contient que des hashs PBKDF2-HMAC-SHA256 (sel aléatoire de 16 octets, 600 000 itérations). L'installeur n'écrit plus aucun mot de passe sur le disque : ils ne sont affichés qu'une fois, à la fin. Un ancien fichier `.env` (versions précédentes) contient des mots de passe en clair : supprimez-le.
- **Fichiers sensibles** : `users.json` et ses copies dans `backup-*` ont des droits Windows limités à votre compte et sont ignorés par Git. Ne les publiez et ne les commitez jamais.
- **Portail d'authentification** : comparaison des hashs en temps constant ; le coût PBKDF2 est payé même pour un identifiant inconnu (le temps de réponse ne révèle pas quels comptes existent) ; corps de requête limité à 4 Ko, délai de 10 s par connexion ; journal d'audit des connexions (`docker compose logs auth-portal`). Le portail tourne en utilisateur non privilégié (uid 65534), système de fichiers en lecture seule.
- **Anti-brute-force** : 5 échecs par couple (adresse IP, identifiant), puis 30 par adresse IP, bloqués 15 minutes. Limite connue : sous Docker Desktop, toutes les connexions arrivent avec l'adresse de la passerelle Docker, donc le blocage joue surtout **par identifiant** ; quelqu'un qui cible un compte peut le verrouiller 15 minutes (compromis assumé, préférable à bloquer tous les comptes).
- **Sessions** : identifiant aléatoire de 256 bits, cookie `HttpOnly`, `Secure`, `SameSite=Strict`. **Déconnexion** = suppression de la session côté serveur (le cookie volé ne sert plus). Sans déconnexion, la session expire après 2 h sans requête HTTP (8 h maximum) ; le trafic d'un flux noVNC déjà ouvert ne compte pas comme une requête HTTP et un flux ouvert n'est pas coupé par le serveur.
- **HTTPS** : certificats Let's Encrypt/ZeroSSL automatiques par Caddy, redirection HTTP vers HTTPS, `Strict-Transport-Security` (1 an).
- **En-têtes** : pages du portail : CSP (`frame-ancestors 'self'`), `X-Frame-Options`, `X-Content-Type-Options`, `Cache-Control: no-store`. Flux du navigateur distant (`/stream/`) : `X-Frame-Options` et `X-Content-Type-Options` (pas de CSP imposée, pour ne pas écraser celle de l'image).
- **Usurpation de l'aiguillage** : Caddy écrase l'en-tête `X-Auth-User` par la valeur fournie par le portail. Un ami connecté qui envoie `X-Auth-User: autre` reste routé vers son propre navigateur. Le cookie de session du portail n'est pas transmis aux conteneurs Firefox.
- **Ports exposés** : seuls `80` et `443` sont publiés sur l'hôte (Caddy). `5800`, `5900` et `8080` ne le sont pas ; ne les redirigez jamais depuis la box.
- **Isolation entre amis** : un réseau Docker par ami, le portail sur un réseau à part, seul Caddy rattaché à tous. Un navigateur distant ne peut joindre ni le navigateur d'un autre ami ni le portail.
- **Conteneurs** : `no-new-privileges`, limites de mémoire (navigateurs : `-FirefoxMemoryLimit`, 3 Go par défaut ; portail : 128 Mo) et de processus, `cap_drop: ALL` pour Caddy (qui ne garde que `NET_BIND_SERVICE`) et pour le portail, rotation des journaux Docker.
- **Fonctionnalités à risque** : le terminal web est désactivé (`WEB_TERMINAL=0`). Le **gestionnaire de fichiers est activé** (transfert de documents) mais limité au dossier `/config/downloads` du conteneur ; pour le désactiver, mettez `WEB_FILE_MANAGER: "0"` dans `compose.yml`.
- **Termux** : noVNC et Nginx n'écoutent que sur `127.0.0.1` (seul le tunnel Cloudflare y accède) ; Nginx demande un identifiant et un mot de passe de 16 caractères minimum (hash apr1 : moins robuste que PBKDF2, d'où la longueur imposée). Testé par analyse statique uniquement, pas sur un téléphone.

## Ce qui n'est PAS protégé (à connaître)

- **Votre PC et votre réseau local** : un navigateur distant est un navigateur placé chez vous. Il peut atteindre les services de votre PC (via `host.docker.internal`, y compris ceux liés à `localhost`) et ceux de votre réseau local (box, NAS, imprimante, caméras...). L'installeur ne bloque pas ces accès. Ne donnez l'accès qu'à des personnes de confiance ; pour aller plus loin, filtrez le trafic sortant des conteneurs avec le pare-feu de votre système.
- **Internet sortant** : tout le trafic des navigateurs sort par votre adresse IP publique (ou celle du téléphone). En cas d'abus, c'est vous qui êtes identifié.
- **Données des amis** : les profils Firefox (`data\<ami>`) contiennent cookies et sessions ; l'administrateur du PC peut y accéder.
- **Tentative ciblée** : un mot de passe faible reste devinable malgré le limiteur. Utilisez des mots de passe longs (12 caractères minimum imposés).
- **Images Docker** : `jlesage/firefox:latest`, `caddy:2` et `python:3-alpine` ne sont pas épinglées par empreinte ; `docker compose pull` récupère leurs mises à jour. Mettez-les à jour régulièrement.
- **Réseau du campus ou de l'entreprise** : contourner un filtrage peut enfreindre son règlement. Vérifiez avant.

## Règles minimales

- Ne jamais publier de mot de passe, token, cookie, clé privée ou fichier `users.json`.
- Révoquer immédiatement tout token GitHub ou secret copié dans un dépôt public ou une conversation.
- Ne pas exposer directement Docker, RDP, VNC, SSH ou les ports internes des navigateurs.
- Un compte par personne, avec un mot de passe unique et long.
- Garder `WEB_TERMINAL: "0"` ; ne mettre `WEB_FILE_MANAGER_ALLOWED_PATHS` sur rien d'autre qu'un dossier isolé.
- Mettre à jour Docker, les images et Termux régulièrement.
- Informer les utilisateurs que leur trafic sort par l'adresse IP de l'hôte.
- Vérifier de temps en temps `docker compose logs auth-portal` : des échecs répétés sur un compte sont un signal.

## Signalement

Ne publiez pas de détails sensibles ou de vulnérabilités dans une issue GitHub publique. Pour signaler un problème de sécurité, ouvrez un canal privé avec les mainteneurs du dépôt et supprimez les secrets exposés avant toute autre action.
