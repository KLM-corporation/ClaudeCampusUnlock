# Sécurité

## Règles minimales

- Ne jamais publier de mot de passe, token, cookie, clé privée ou fichier `.env`.
- Révoquer immédiatement tout token GitHub ou secret copié dans un dépôt public ou une conversation.
- Utiliser HTTPS pour toute interface accessible depuis Internet.
- Ne pas exposer directement Docker, RDP, VNC, SSH ou les ports internes des navigateurs.
- Activer une authentification unique et forte par utilisateur.
- Garder `WEB_TERMINAL=0`.
- Limiter le gestionnaire de fichiers à un dossier isolé si son activation est nécessaire.
- Mettre à jour Docker, les images et Termux régulièrement.
- Utiliser un conteneur ou une session séparée par personne lorsque c’est possible.
- Informer les utilisateurs que leur trafic sort par l’adresse IP de l’hôte.

## Signalement

Ne publiez pas de détails sensibles dans une issue GitHub. Pour un problème de sécurité, ouvrez une discussion privée avec les mainteneurs du dépôt et supprimez les secrets exposés avant toute autre action.
