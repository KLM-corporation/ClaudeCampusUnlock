# Variante Termux / Android

Cette variante ne lance pas Docker. Elle utilise :

```text
Chromium dans Debian/proot-distro
    -> Xvfb
    -> x11vnc
    -> noVNC
    -> Nginx avec authentification
    -> Cloudflare Quick Tunnel
```

Les amis ouvrent une URL HTTPS dans leur navigateur et contrôlent le navigateur Chromium qui tourne sur le téléphone. Claude voit donc la connexion 4G du téléphone.

## Limites importantes

- Cette version gère **une session Chromium partagée**.
- Elle est expérimentale et consomme beaucoup plus de batterie et de données qu'une simple page web.
- Le téléphone doit rester allumé, connecté en 4G et avec Termux exclu de l'optimisation batterie.
- L'URL du Quick Tunnel change après chaque redémarrage.
- Le PC ou le routeur ne sont pas nécessaires.
- Le téléphone mobile est généralement derrière un CGNAT : le DynDNS n'est pas utilisé ici.
- Chaque personne qui obtient l'URL et le mot de passe peut contrôler le navigateur. Ne les partage qu'avec des personnes de confiance.

## Installation

Copie `termux-browser-gateway.sh` dans le dossier personnel de Termux, puis :

```bash
chmod 700 termux-browser-gateway.sh
./termux-browser-gateway.sh install
```

Le script installe :

- Debian avec `proot-distro` ;
- Chromium ;
- Xvfb ;
- x11vnc ;
- noVNC ;
- Nginx ;
- cloudflared.

La première installation de Debian et de Chromium peut être longue et télécharger plusieurs centaines de mégaoctets.

## Démarrage

```bash
termux-wake-lock
./termux-browser-gateway.sh start
```

`cloudflared` affichera une URL du type :

```text
https://quelque-chose.trycloudflare.com
```

Ton ami ouvre cette URL dans son navigateur. Si la page noVNC ne se connecte pas automatiquement, ajoute :

```text
/vnc.html?autoconnect=1
```

Exemple :

```text
https://quelque-chose.trycloudflare.com/vnc.html?autoconnect=1
```

Il devra saisir le nom d'utilisateur et le mot de passe créés par le script. Il pourra ensuite ouvrir ou utiliser Claude dans Chromium.

## Arrêt

Appuie sur `Ctrl+C` dans Termux pour arrêter le tunnel et les processus, ou exécute :

```bash
./termux-browser-gateway.sh stop
termux-wake-unlock
```

## Journaux Chromium

En cas de problème :

```bash
proot-distro login debian -- bash -lc 'cat /root/claude-browser-logs/*.log'
```

## Sécurité

- Le script ne crée pas un proxy SOCKS/HTTP ouvert.
- N'utilise pas le même mot de passe que ton compte Claude.
- Chaque ami doit utiliser son propre compte Claude.
- Ne mets aucun token GitHub, cookie ou mot de passe Claude dans le script.
- Un Quick Tunnel est pratique pour tester, mais pas idéal pour un service permanent. Pour une URL stable, remplace-le ensuite par un tunnel Cloudflare nommé avec une politique d'accès.
