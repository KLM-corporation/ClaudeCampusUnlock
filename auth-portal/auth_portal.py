#!/usr/bin/env python3
"""
ClaudeCampusUnlock - Auth Portal & Session Gateway
=================================================
Portail d'authentification et gestionnaire de sessions.
- Mots de passe hashés avec PBKDF2-HMAC-SHA256 salé (zéro clair).
- Le coût PBKDF2 est payé même pour un identifiant inconnu : le temps de
  réponse ne révèle pas quels identifiants existent.
- Anti-brute-force : compteur par couple (IP, identifiant) + plafond par IP.
- Sessions révocables côté serveur (supprimées au logout), purgées à l'expiration.
- Corps de requête borné et timeout sur chaque connexion.
- En-têtes de sécurité (CSP, X-Frame-Options, no-store) et cookie HttpOnly/Secure/SameSite=Strict.
- Journal d'audit des connexions (succès / échecs) avec l'IP client.
"""

import html
import http.server
import ipaddress
import json
import os
import secrets
import sys
import threading
import time
import urllib.parse
from hashlib import pbkdf2_hmac

USERS_FILE = os.environ.get("USERS_FILE", "/app/users.json")
LISTEN_PORT = int(os.environ.get("PORT", "8080"))
SESSION_MAX_LIFETIME = int(os.environ.get("SESSION_MAX_LIFETIME", "28800"))  # 8 heures max
SESSION_IDLE_TIMEOUT = int(os.environ.get("SESSION_IDLE_TIMEOUT", "7200"))   # 2 heures sans requête HTTP
RATE_LIMIT_MAX_ATTEMPTS = int(os.environ.get("RATE_LIMIT_MAX_ATTEMPTS", "5"))  # échecs par (IP, identifiant)
RATE_LIMIT_IP_MAX = int(os.environ.get("RATE_LIMIT_IP_MAX", "30"))             # échecs par IP, tous identifiants
RATE_LIMIT_WINDOW = 900  # 15 minutes
MAX_BODY_BYTES = 4096    # un formulaire de connexion tient largement dans 4 Ko
MAX_USERNAME_LEN = 64
REQUEST_TIMEOUT = 10     # secondes, par opération de lecture/écriture sur la connexion
DEFAULT_ITERATIONS = 600000
COOKIE_NAME = "gateway_session"

# Sessions en mémoire : session_id -> { "user": str, "created_at": float, "last_seen": float }
sessions = {}
sessions_lock = threading.Lock()

# Échecs récents : ("ip", ip) ou ("user", ip, identifiant) -> [timestamps]
failed_attempts = {}
attempts_lock = threading.Lock()

# Enregistrement factice : il sert à dépenser le même coût PBKDF2 quand l'identifiant
# n'existe pas (sinon un identifiant inconnu répond nettement plus vite qu'un connu).
_DUMMY_RECORD = {"salt": secrets.token_hex(16), "hash": "0" * 64, "iterations": DEFAULT_ITERATIONS}


def audit(event, username, ip):
    """Journal d'audit sur stdout (visible avec `docker compose logs auth-portal`)."""
    # ascii() échappe retours à la ligne et caractères non ASCII : pas d'injection dans les logs.
    safe_name = ascii(str(username)[:MAX_USERNAME_LEN])
    sys.stdout.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] [AUTH] {event} user={safe_name} ip={ip}\n")
    sys.stdout.flush()


def load_users():
    """Charge la base des utilisateurs avec leurs hashs PBKDF2."""
    if not os.path.exists(USERS_FILE):
        return {}
    try:
        with open(USERS_FILE, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except Exception as e:
        print(f"[AUTH ERROR] Impossible de lire {USERS_FILE}: {e}", file=sys.stderr)
        return {}
    if not isinstance(data, dict):
        print(f"[AUTH ERROR] {USERS_FILE} doit contenir un objet JSON {{identifiant: {{salt, hash, iterations}}}}", file=sys.stderr)
        return {}
    return data


def verify_password(user_record, password):
    """Vérifie le mot de passe avec PBKDF2, puis compare les hashs en temps constant."""
    if not isinstance(user_record, dict) or "salt" not in user_record or "hash" not in user_record:
        return False
    try:
        salt = bytes.fromhex(user_record["salt"])
        stored_hash = user_record["hash"]
        iterations = int(user_record.get("iterations", DEFAULT_ITERATIONS))
        if not 1 <= iterations <= 10_000_000:
            return False
        computed_hash = pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations).hex()
        return secrets.compare_digest(computed_hash, stored_hash)
    except Exception as e:
        print(f"[AUTH ERROR] Échec vérification PBKDF2: {e}", file=sys.stderr)
        return False


def authenticate(users, username, password):
    """Retourne l'identifiant canonique (minuscules) si les identifiants sont valides, sinon None.

    Le même travail PBKDF2 est effectué que l'identifiant existe ou non.
    """
    wanted = username.lower()
    canonical, record = None, None
    for key, value in users.items():
        if key.lower() == wanted:
            canonical, record = key.lower(), value
            break
    ok = verify_password(record if record is not None else _DUMMY_RECORD, password)
    return canonical if (ok and record is not None) else None


def _recent(key, now):
    """Timestamps d'échecs encore dans la fenêtre pour `key` (à appeler avec attempts_lock)."""
    timestamps = [t for t in failed_attempts.get(key, ()) if now - t < RATE_LIMIT_WINDOW]
    if timestamps:
        failed_attempts[key] = timestamps
    else:
        failed_attempts.pop(key, None)
    return timestamps


def _prune_attempts(now):
    """Évite que le dictionnaire grossisse indéfiniment (à appeler avec attempts_lock)."""
    if len(failed_attempts) > 1000:
        for key in list(failed_attempts):
            _recent(key, now)


def is_rate_limited(ip, username):
    """Vrai si l'IP a trop échoué en général, ou trop échoué sur cet identifiant."""
    now = time.time()
    with attempts_lock:
        if len(_recent(("ip", ip), now)) >= RATE_LIMIT_IP_MAX:
            return True
        return len(_recent(("user", ip, username), now)) >= RATE_LIMIT_MAX_ATTEMPTS


def record_failed_attempt(ip, username):
    """Enregistre un échec de connexion pour l'IP et pour le couple (IP, identifiant)."""
    now = time.time()
    with attempts_lock:
        for key in (("ip", ip), ("user", ip, username)):
            timestamps = _recent(key, now)
            timestamps.append(now)
            failed_attempts[key] = timestamps
        _prune_attempts(now)


def reset_failed_attempts(ip, username):
    """Réinitialise le compteur du couple (IP, identifiant) après une connexion réussie.

    Le plafond par IP n'est volontairement pas remis à zéro : il borne le total d'échecs.
    """
    with attempts_lock:
        failed_attempts.pop(("user", ip, username), None)


def parse_cookie(cookie_header):
    """Extrait la valeur du cookie de session."""
    if not cookie_header:
        return None
    for item in cookie_header.split(";"):
        parts = item.strip().split("=", 1)
        if len(parts) == 2 and parts[0] == COOKIE_NAME:
            return parts[1]
    return None


def get_authenticated_user(cookie_value):
    """Retourne le nom d'utilisateur si la session est active et valide."""
    if not cookie_value:
        return None
    now = time.time()
    with sessions_lock:
        session = sessions.get(cookie_value)
        if not session:
            return None
        # Expiration absolue
        if now - session["created_at"] > SESSION_MAX_LIFETIME:
            sessions.pop(cookie_value, None)
            return None
        # Expiration par inactivité (comptée sur les requêtes HTTP passant par /verify)
        if now - session["last_seen"] > SESSION_IDLE_TIMEOUT:
            sessions.pop(cookie_value, None)
            return None
        # Rafraîchir l'inactivité
        session["last_seen"] = now
        return session["user"]


def purge_expired_sessions():
    """Supprime les sessions expirées qui ne seraient plus jamais présentées."""
    now = time.time()
    with sessions_lock:
        expired = [sid for sid, s in sessions.items()
                   if now - s["created_at"] > SESSION_MAX_LIFETIME or now - s["last_seen"] > SESSION_IDLE_TIMEOUT]
        for sid in expired:
            del sessions[sid]


LOGIN_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Connexion — ClaudeCampusUnlock</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
        body {
            background: linear-gradient(135deg, #090d16 0%, #111827 50%, #1e1b4b 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #f3f4f6;
            padding: 16px;
        }
        .card {
            background: rgba(30, 41, 59, 0.85);
            backdrop-filter: blur(16px);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 16px;
            padding: 36px 32px;
            width: 100%;
            max-width: 400px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
        }
        .header { text-align: center; margin-bottom: 28px; }
        .logo-icon {
            font-size: 40px;
            margin-bottom: 12px;
            display: inline-block;
            background: rgba(99, 102, 241, 0.15);
            padding: 12px;
            border-radius: 12px;
            border: 1px solid rgba(99, 102, 241, 0.3);
        }
        h1 { font-size: 22px; font-weight: 700; color: #fff; margin-bottom: 6px; }
        p.subtitle { font-size: 13px; color: #94a3b8; }
        .alert {
            background: rgba(239, 68, 68, 0.15);
            border: 1px solid rgba(239, 68, 68, 0.4);
            color: #fca5a5;
            padding: 12px 14px;
            border-radius: 8px;
            font-size: 13px;
            margin-bottom: 20px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .form-group { margin-bottom: 18px; }
        label { display: block; font-size: 13px; font-weight: 500; color: #cbd5e1; margin-bottom: 6px; }
        input[type="text"], input[type="password"] {
            width: 100%;
            padding: 12px 14px;
            background: rgba(15, 23, 42, 0.8);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 8px;
            color: #fff;
            font-size: 14px;
            outline: none;
            transition: all 0.2s;
        }
        input[type="text"]:focus, input[type="password"]:focus {
            border-color: #6366f1;
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.25);
        }
        button.btn-submit {
            width: 100%;
            padding: 12px;
            background: #4f46e5;
            color: #fff;
            border: none;
            border-radius: 8px;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
            transition: background 0.2s, transform 0.1s;
            margin-top: 8px;
        }
        button.btn-submit:hover { background: #4338ca; }
        button.btn-submit:active { transform: scale(0.98); }
        .footer-note { text-align: center; margin-top: 24px; font-size: 11px; color: #64748b; }
    </style>
</head>
<body>
    <div class="card">
        <div class="header">
            <div class="logo-icon">🔒</div>
            <h1>ClaudeCampusUnlock</h1>
            <p class="subtitle">Accès distant sécurisé à Claude.ai</p>
        </div>
        __ERROR_ALERT__
        <form method="POST" action="/login">
            <div class="form-group">
                <label for="username">Identifiant de session</label>
                <input type="text" id="username" name="username" placeholder="ex: gabi" required autofocus autocomplete="username">
            </div>
            <div class="form-group">
                <label for="password">Mot de passe</label>
                <input type="password" id="password" name="password" placeholder="••••••••" required autocomplete="current-password">
            </div>
            <button type="submit" class="btn-submit">Se connecter</button>
        </form>
        <div class="footer-note">
            🛡️ Session chiffrée de bout en bout • Invalidation automatique
        </div>
    </div>
</body>
</html>
"""

PORTAL_HTML_TEMPLATE = """<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Claude — Session de __USER_ESCAPED__</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
        html, body { height: 100%; width: 100%; overflow: hidden; background: #0f172a; }
        #topbar {
            height: 42px;
            background: #1e293b;
            border-bottom: 1px solid #334155;
            display: flex;
            align-items: center;
            justify-content: space-between;
            padding: 0 16px;
            color: #e2e8f0;
            font-size: 13px;
            z-index: 1000;
        }
        .brand { display: flex; align-items: center; gap: 8px; font-weight: 600; color: #fff; }
        .user-tag {
            background: rgba(99, 102, 241, 0.2);
            color: #a5b4fc;
            border: 1px solid rgba(99, 102, 241, 0.4);
            padding: 3px 10px;
            border-radius: 9999px;
            font-size: 12px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .status-dot { width: 7px; height: 7px; background: #22c55e; border-radius: 50%; display: inline-block; box-shadow: 0 0 6px #22c55e; }
        .actions { display: flex; align-items: center; gap: 10px; }
        .btn-fullscreen {
            background: #334155;
            color: #cbd5e1;
            border: 1px solid #475569;
            padding: 5px 12px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
        }
        .btn-fullscreen:hover { background: #475569; color: #fff; }
        .btn-files {
            background: rgba(99, 102, 241, 0.2);
            color: #c7d2fe;
            border: 1px solid rgba(99, 102, 241, 0.4);
            padding: 5px 12px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 500;
            cursor: pointer;
            transition: all 0.2s;
            display: flex;
            align-items: center;
            gap: 6px;
        }
        .btn-files:hover { background: rgba(99, 102, 241, 0.4); color: #fff; }
        .btn-logout {
            background: #dc2626;
            color: #fff;
            text-decoration: none;
            padding: 5px 14px;
            border-radius: 6px;
            font-size: 12px;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 6px;
            transition: background 0.2s;
        }
        .btn-logout:hover { background: #b91c1c; }
        #workspace {
            width: 100%;
            height: calc(100% - 42px);
            background: #000;
            position: relative;
        }
        iframe {
            width: 100%;
            height: 100%;
            border: none;
            display: block;
        }
    </style>
</head>
<body>
    <div id="topbar">
        <div style="display: flex; align-items: center; gap: 14px;">
            <div class="brand">🔒 ClaudeCampusUnlock</div>
            <div class="user-tag">
                <span class="status-dot"></span>
                <span>__USER_ESCAPED__</span>
            </div>
        </div>
        <div class="actions">
            <button id="fmBtn" class="btn-files" onclick="openFileManager()" title="Accéder aux téléchargements et envoyer des fichiers">📁 Fichiers / Téléchargements</button>
            <button id="fsBtn" class="btn-fullscreen" onclick="toggleFullscreen()" title="Basculer en plein écran">⛶ Plein écran</button>
            <a href="/logout" class="btn-logout" title="Fermer la session immédiatement">🚪 Déconnexion</a>
        </div>
    </div>
    <div id="workspace">
        <iframe id="desktopFrame" src="/stream/" allow="fullscreen; clipboard-read; clipboard-write"></iframe>
    </div>

    <script>
        function openFileManager() {
            try {
                var iframe = document.getElementById('desktopFrame');
                if (iframe && iframe.contentWindow && iframe.contentDocument) {
                    var btn = iframe.contentDocument.getElementById('noVNC_file_manager_button');
                    if (btn) {
                        btn.click();
                        return;
                    }
                }
            } catch(e) {}
            alert("Pour récupérer vos téléchargements ou envoyer un fichier : cliquez sur l'icône 📁 Dossier dans le menu latéral gauche de l'écran.");
        }
        function toggleFullscreen() {
            var elem = document.documentElement;
            if (!document.fullscreenElement) {
                if (elem.requestFullscreen) { elem.requestFullscreen(); }
                document.getElementById('fsBtn').innerText = '⛶ Quitter plein écran';
            } else {
                if (document.exitFullscreen) { document.exitFullscreen(); }
                document.getElementById('fsBtn').innerText = '⛶ Plein écran';
            }
        }
        document.addEventListener('fullscreenchange', function() {
            if (!document.fullscreenElement) {
                document.getElementById('fsBtn').innerText = '⛶ Plein écran';
            }
        });
    </script>
</body>
</html>
"""


class AuthGatewayHandler(http.server.BaseHTTPRequestHandler):
    # Coupe les connexions qui n'envoient plus rien (évite de garder un thread indéfiniment).
    timeout = REQUEST_TIMEOUT

    def version_string(self):
        return "auth-portal"  # ne révèle pas la version de Python

    def log_message(self, format, *args):
        sys.stdout.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.get_client_ip()} - {format % args}\n")
        sys.stdout.flush()

    def get_client_ip(self):
        """IP du client telle que vue par Caddy (dernier élément de X-Forwarded-For).

        Caddy remplace X-Forwarded-For par l'adresse de son client direct : on prend donc
        le dernier élément, celui ajouté par le proxy de confiance, et jamais une valeur
        fournie par le client. Une valeur invalide retombe sur l'adresse de la connexion TCP.
        """
        forwarded = self.headers.get("X-Forwarded-For")
        if forwarded:
            candidate = forwarded.split(",")[-1].strip()
            try:
                return str(ipaddress.ip_address(candidate))
            except ValueError:
                pass
        return self.client_address[0]

    def add_security_headers(self):
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-src 'self'; img-src 'self' data:; frame-ancestors 'self';")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")

    def _respond(self, status, body=b"", content_type=None, headers=(), hardened=False):
        """Envoie une réponse complète. Pour HEAD, mêmes en-têtes que GET mais sans corps."""
        self.send_response(status)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers:
            self.send_header(name, value)
        if hardened:
            self.add_security_headers()
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _redirect(self, location, headers=()):
        self._respond(302, b"", headers=(("Location", location), *headers))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        cookie_val = parse_cookie(self.headers.get("Cookie"))
        user = get_authenticated_user(cookie_val)

        # 1. Endpoint /verify (utilisé par Caddy forward_auth). HEAD donne la même réponse que GET.
        if path == "/verify":
            if user:
                self._respond(200, b"OK", "text/plain", (("X-Auth-User", user),))
            else:
                self._redirect("/login")
            return

        # 2. Endpoint /logout (un HEAD n'a pas d'effet de bord)
        if path == "/logout":
            if cookie_val and self.command != "HEAD":
                with sessions_lock:
                    sessions.pop(cookie_val, None)
            self._redirect("/login", (
                ("Set-Cookie", f"{COOKIE_NAME}=deleted; Path=/; Max-Age=0; HttpOnly; SameSite=Strict; Secure"),
                ("Clear-Site-Data", '"cache", "cookies", "storage"'),
            ))
            return

        # 3. Endpoint /login (affichage de la page)
        if path == "/login" or path == "/login/":
            if user:
                # Déjà connecté, rediriger vers le portail
                self._redirect("/portal")
                return

            error_msg = ""
            params = urllib.parse.parse_qs(parsed.query)
            if "error" in params:
                err_code = params["error"][0]
                if err_code == "rate_limited":
                    error_msg = '<div class="alert">⚠️ Trop d\'échecs consécutifs. Réessaie dans 15 minutes.</div>'
                else:
                    error_msg = '<div class="alert">❌ Identifiant ou mot de passe incorrect.</div>'

            body = LOGIN_HTML_TEMPLATE.replace("__ERROR_ALERT__", error_msg).encode("utf-8")
            self._respond(200, body, "text/html; charset=utf-8", hardened=True)
            return

        # 4. Endpoint /portal ou / (wrapper avec topbar et iframe)
        if path in ["/", "/portal", "/portal/"]:
            if not user:
                self._redirect("/login")
                return

            escaped_user = html.escape(user)
            body = PORTAL_HTML_TEMPLATE.replace("__USER_ESCAPED__", escaped_user).encode("utf-8")
            self._respond(200, body, "text/html; charset=utf-8", hardened=True)
            return

        # Page non trouvée
        self._respond(404, b"404 Not Found", "text/plain")

    do_HEAD = do_GET

    def _content_length(self):
        """Taille du corps annoncée, ou None si l'en-tête est invalide (négatif, texte...)."""
        raw = self.headers.get("Content-Length")
        if raw is None:
            return 0
        raw = raw.strip()
        if not (raw.isascii() and raw.isdigit()):
            return None
        if len(raw) > 9:  # évite de convertir des entiers absurdes
            return MAX_BODY_BYTES + 1
        return int(raw)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path

        if path != "/login" and path != "/login/":
            self._respond(404, b"404 Not Found", "text/plain")
            return

        length = self._content_length()
        if length is None:
            self.close_connection = True
            self._respond(400, b"Bad Request", "text/plain")
            return
        if length > MAX_BODY_BYTES:
            self.close_connection = True
            self._respond(413, b"Payload Too Large", "text/plain")
            return

        try:
            post_data = self.rfile.read(length).decode("utf-8", errors="ignore")
            form_data = urllib.parse.parse_qs(post_data, max_num_fields=10)
        except (OSError, ValueError):  # timeout, connexion coupée ou formulaire abusif
            self.close_connection = True
            return

        client_ip = self.get_client_ip()
        username = form_data.get("username", [""])[0].strip()[:MAX_USERNAME_LEN]
        password = form_data.get("password", [""])[0]
        attempt_key = username.lower()

        users = load_users()
        # On ne journalise que les identifiants qui existent : un mot de passe tapé par erreur
        # dans le champ identifiant ne doit pas finir dans les logs.
        log_name = attempt_key if any(k.lower() == attempt_key for k in users) else "<inconnu>"

        # Vérification Rate Limit (par IP et par couple IP + identifiant)
        if is_rate_limited(client_ip, attempt_key):
            audit("login blocked (rate limit)", log_name, client_ip)
            self._redirect("/login?error=rate_limited")
            return

        canonical_user = authenticate(users, username, password)

        if canonical_user:
            # Succès ! Réinitialiser les échecs de ce couple
            reset_failed_attempts(client_ip, attempt_key)
            purge_expired_sessions()
            # Générer un session ID sécurisé (256 bits d'entropie)
            session_id = secrets.token_urlsafe(32)
            now = time.time()
            with sessions_lock:
                sessions[session_id] = {
                    "user": canonical_user,
                    "created_at": now,
                    "last_seen": now
                }
            audit("login ok", canonical_user, client_ip)
            # Cookie de session : pas de Max-Age fixe (détruit quand le navigateur est fermé)
            self._redirect("/portal", (
                ("Set-Cookie", f"{COOKIE_NAME}={session_id}; Path=/; HttpOnly; SameSite=Strict; Secure"),
            ))
        else:
            record_failed_attempt(client_ip, attempt_key)
            audit("login failed", log_name, client_ip)
            self._redirect("/login?error=invalid")


def run_server():
    server_address = ("0.0.0.0", LISTEN_PORT)
    httpd = http.server.ThreadingHTTPServer(server_address, AuthGatewayHandler)
    print(f"[AUTH PORTAL] Démarrage sur le port {LISTEN_PORT}...", flush=True)
    if not load_users():
        print(f"[AUTH PORTAL] Attention : aucun utilisateur chargé depuis {USERS_FILE}.", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    run_server()
