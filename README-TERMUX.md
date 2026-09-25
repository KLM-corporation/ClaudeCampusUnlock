# Variante Termux / Android — ClaudeCampusUnlock 📱

> **Guide complet pour déployer la passerelle Claude sur un smartphone Android avec Termux et Cloudflare Tunnel.**  
> Pour la documentation générale et la méthode Windows + Docker, consultez le [README principal](README.md).

---

## 🎯 Principe de fonctionnement

Cette variante n'utilise ni PC, ni Docker, ni redirection de box Internet. Votre smartphone Android sert directement de serveur relais :

```text
Chromium (dans Debian / proot-distro)
    -> Xvfb (écran virtuel)
    -> x11vnc (serveur VNC)
    -> noVNC (interface web HTML5)
    -> Nginx (authentification par mot de passe)
    -> Cloudflare Quick Tunnel (URL HTTPS publique temporaire)
```

Votre ami distant ouvre simplement l'URL générée dans son navigateur web. Il contrôle le navigateur Chromium s'exécutant sur votre téléphone. Pour Claude.ai, la requête provient directement de la connexion 4G/5G de votre téléphone portable !

---

## ⚠️ Avertissement capital : Où télécharger Termux ?

> [!CAUTION]
> **N'installez JAMAIS Termux depuis le Google Play Store !**  
> L'application présente sur le Play Store est obsolète depuis 2020. Ses dépôts sont désactivés et `pkg update` renverra systématiquement des erreurs `404 Not Found`.  
> 
> Vous devez impérativement télécharger Termux depuis :
> - **[F-Droid (Recommandé)](https://f-droid.org/fr/packages/com.termux/)**
> - ou les **[Releases GitHub officielles](https://github.com/termux/termux-app/releases)** (téléchargez l'APK correspondant à votre processeur, généralement `termux-app_..._arm64-v8a.apk`).

---

## 🚀 Installation rapide (One-Liner)

1. Ouvrez Termux sur votre téléphone Android.
2. Copiez et collez la commande suivante :

```bash
pkg update -y && pkg install -y git
git clone https://github.com/KLM-corporation/ClaudeCampusUnlock.git
cd ClaudeCampusUnlock
chmod +x termux-browser-gateway.sh
./termux-browser-gateway.sh install
```

Le script installe automatiquement :
- L'environnement Debian via `proot-distro`
- Chromium, Xvfb, x11vnc et noVNC
- Nginx et Cloudflared
- Il vous demandera ensuite de définir un **nom d'utilisateur** et un **mot de passe** pour sécuriser l'accès.

*(La première installation peut prendre entre 3 et 5 minutes selon le débit de votre connexion).*

---

## 🌐 Démarrage de la passerelle

Pour démarrer le service lorsque votre ami en a besoin :

```bash
cd ~/ClaudeCampusUnlock
./termux-browser-gateway.sh start
```

Termux affichera en quelques secondes l'URL du tunnel Cloudflare, par exemple :
```text
https://random-subdomain.trycloudflare.com
```

### Accès pour votre ami
Transmettez cette adresse à votre ami. Pour qu'il accède directement à l'écran sans manipulation :
```text
https://random-subdomain.trycloudflare.com/vnc.html?autoconnect=1
```
Il saisit l'identifiant et le mot de passe que vous avez configurés, puis le navigateur Chromium s'ouvre sur Claude.ai !

---

## 🛑 Arrêt de la passerelle

Pour couper la passerelle et libérer les ressources :
- Appuyez simplement sur `Ctrl + C` dans Termux.
- Ou dans une autre session Termux :
```bash
./termux-browser-gateway.sh stop
```

---

## 🔋 Économie de batterie et veille Android

Par défaut, Android met en veille prolongée les applications tournant en arrière-plan. Pour que votre passerelle reste active :
1. Allez dans **Paramètres Android** > **Applications** > **Termux**.
2. Dans **Batterie**, choisissez **Non restreinte** (ou désactivez l'optimisation de batterie).
3. Le script active automatiquement `termux-wake-lock` pour empêcher le processeur d'entrer en veille pendant que le tunnel est ouvert.

---

## 📋 Presse-papier (Copier / Coller)

noVNC dispose d'un panneau latéral :
- Sur le bord gauche de l'écran du navigateur distant, cliquez sur la petite flèche grise pour dérouler le menu noVNC.
- Cliquez sur l'icône du **Presse-papier** (Clipboard) pour y coller du texte ou récupérer le texte copié dans Chromium.

---

## 🔍 Diagnostic et Journaux

Si le navigateur ne s'affiche pas :
```bash
# Vérifier l'état des services
./termux-browser-gateway.sh status

# Consulter les journaux internes de Debian
proot-distro login debian -- bash -lc 'cat /root/claude-browser-logs/*.log'
```

---

## 🔒 Sécurité

- Ne réutilisez jamais le mot de passe de votre propre compte Claude pour la passerelle.
- Chaque ami doit se connecter avec son propre compte personnel.
- Consultez [SECURITY.md](SECURITY.md) pour les recommandations complètes.
