# Sécurité

## Règles minimales

- **Zéro mot de passe en clair** : Les identifiants stockés dans `users.json` utilisent un sel cryptographique aléatoire de 16 octets et un hashage PBKDF2-HMAC-SHA256 (600 000 itérations).
- **Protection des fichiers sensibles** : Ne jamais publier ni commiter les fichiers `.env` ou `users.json`. Ils sont ignorés par Git et restreints avec des permissions locales strictes.
- **Protection Anti-Brute-Force** : Le portail bloque automatiquement toute IP tentant plus de 5 faux mots de passe consécutifs pendant 15 minutes.
- **Sessions éphémères & Révocation** : Le cookie `gateway_session` est protégé par les drapeaux `HttpOnly`, `Secure` et `SameSite=Strict`. Un clic sur `Déconnexion` révoque instantanément la session en mémoire serveur. Fermer le navigateur détruit également le cookie éphémère.
- **HTTPS obligatoire** : Caddy génère et renouvelle automatiquement un certificat TLS Let's Encrypt / ZeroSSL. Aucune connexion non chiffrée n'est autorisée.
- **Ports exposés strictement limités** : Seuls les ports `80` et `443` sont ouverts. Ne jamais exposer directement `5800`, `5900`, Docker ou RDP sur Internet.
- **Protection contre le Clickjacking** : En-têtes `Content-Security-Policy: frame-ancestors 'self'` et `X-Frame-Options: SAMEORIGIN` configurés sur toutes les interfaces.
- **Fonctionnalités à risque désactivées** : `WEB_TERMINAL=0` et `WEB_FILE_MANAGER=0` pour empêcher toute exécution de commandes ou navigation sur le système hôte.
- **Cercle de confiance** : Tout le trafic sortant de la passerelle utilise l'adresse IP de l'hôte. Ne partagez l'accès qu'à des personnes de confiance.

## Signalement

Ne publiez pas de détails sensibles ou de vulnérabilités dans une issue GitHub publique. Pour signaler un problème de sécurité, ouvrez un canal privé avec les mainteneurs du dépôt.

