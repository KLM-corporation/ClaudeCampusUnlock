#!/usr/bin/env python3
"""
ClaudeCampusUnlock - Auth Portal & Session Gateway
=================================================
Portail d'authentification et gestionnaire de sessions sécurisées.
- Mots de passe hashés avec PBKDF2-HMAC-SHA256 salé (zéro clair).
- Protection anti-brute-force (rate limiting par IP).
- Sessions révocables côté serveur (kill immédiat au logout).
- Protection anti-timing attacks (secrets.compare_digest).
- En-têtes de sécurité stricts (CSP, X-Frame-Options, HttpOnly, Secure, SameSite=Strict).
"""

import html
import http.server
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
SESSION_IDLE_TIMEOUT = int(os.environ.get("SESSION_IDLE_TIMEOUT", "7200"))   # 2 heures inactif
RATE_LIMIT_MAX_ATTEMPTS = 5
RATE_LIMIT_WINDOW = 900  # 15 minutes
COOKIE_NAME = "gateway_session"

# Sessions en mémoire : session_id -> { "user": str, "created_at": float, "last_seen": float }
sessions = {}
sessions_lock = threading.Lock()

# Tentatives échouées : ip -> [timestamps]
failed_attempts = {}
attempts_lock = threading.Lock()


def load_users():
    """Charge la base des utilisateurs avec leurs hashs PBKDF2."""
    if not os.path.exists(USERS_FILE):
        return {}
    try:
        with open(USERS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        print(f"[AUTH ERROR] Impossible de lire {USERS_FILE}: {e}", file=sys.stderr)
        return {}


def verify_password(user_record, password):
    """Vérifie le mot de passe en temps constant avec PBKDF2."""
    if not user_record or "salt" not in user_record or "hash" not in user_record:
        return False
    try:
        salt = bytes.fromhex(user_record["salt"])
        stored_hash = user_record["hash"]
        iterations = int(user_record.get("iterations", 600000))
        computed_hash = pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations).hex()
        return secrets.compare_digest(computed_hash, stored_hash)
    except Exception as e:
        print(f"[AUTH ERROR] Échec vérification PBKDF2: {e}", file=sys.stderr)
        return False


def is_rate_limited(ip):
    """Vérifie si l'adresse IP dépasse le quota de tentatives échouées."""
    now = time.time()
    with attempts_lock:
        timestamps = [t for t in failed_attempts.get(ip, []) if now - t < RATE_LIMIT_WINDOW]
        failed_attempts[ip] = timestamps
        return len(timestamps) >= RATE_LIMIT_MAX_ATTEMPTS


def record_failed_attempt(ip):
    """Enregistre un échec de connexion pour l'adresse IP."""
    now = time.time()
    with attempts_lock:
        timestamps = [t for t in failed_attempts.get(ip, []) if now - t < RATE_LIMIT_WINDOW]
        timestamps.append(now)
        failed_attempts[ip] = timestamps


def reset_failed_attempts(ip):
    """Réinitialise les échecs après une connexion réussie."""
    with attempts_lock:
        failed_attempts.pop(ip, None)


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
        # Expiration par inactivité
        if now - session["last_seen"] > SESSION_IDLE_TIMEOUT:
            sessions.pop(cookie_value, None)
            return None
        # Rafraîchir l'inactivité
        session["last_seen"] = now
        return session["user"]


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
            <button id="fsBtn" class="btn-fullscreen" onclick="toggleFullscreen()" title="Basculer en plein écran">⛶ Plein écran</button>
            <a href="/logout" class="btn-logout" title="Fermer la session immédiatement">🚪 Déconnexion</a>
        </div>
    </div>
    <div id="workspace">
        <iframe id="desktopFrame" src="/stream/" allow="fullscreen; clipboard-read; clipboard-write"></iframe>
    </div>

    <script>
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
    def log_message(self, format, *args):
        # Format propre des logs
        sys.stdout.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.client_address[0]} - {format % args}\n")
        sys.stdout.flush()

    def get_client_ip(self):
        # Récupère la vraie IP via X-Forwarded-For si présent (de Caddy)
        forwarded = self.headers.get("X-Forwarded-For")
        if forwarded:
            return forwarded.split(",")[0].strip()
        return self.client_address[0]

    def add_security_headers(self):
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-src 'self'; img-src 'self' data:; frame-ancestors 'self';")
        self.send_header("X-Frame-Options", "SAMEORIGIN")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "strict-origin-when-cross-origin")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        client_ip = self.get_client_ip()
        cookie_val = parse_cookie(self.headers.get("Cookie"))
        user = get_authenticated_user(cookie_val)

        # 1. Endpoint /verify (utilisé par Caddy forward_auth)
        if path == "/verify":
            if user:
                self.send_response(200)
                self.send_header("X-Auth-User", user)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"OK")
            else:
                self.send_response(302)
                self.send_header("Location", "/login")
                self.send_header("Content-Length", "0")
                self.end_headers()
            return

        # 2. Endpoint /logout
        if path == "/logout":
            if cookie_val:
                with sessions_lock:
                    sessions.pop(cookie_val, None)
            self.send_response(302)
            self.send_header("Location", "/login")
            self.send_header("Set-Cookie", f"{COOKIE_NAME}=deleted; Path=/; Max-Age=0; HttpOnly; SameSite=Strict; Secure")
            self.send_header("Clear-Site-Data", '"cache", "cookies", "storage"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # 3. Endpoint /login (affichage de la page)
        if path == "/login" or path == "/login/":
            if user:
                # Déjà connecté, rediriger vers le portail
                self.send_response(302)
                self.send_header("Location", "/portal")
                self.send_header("Content-Length", "0")
                self.end_headers()
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
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.add_security_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # 4. Endpoint /portal ou / (wrapper avec topbar et iframe)
        if path in ["/", "/portal", "/portal/"]:
            if not user:
                self.send_response(302)
                self.send_header("Location", "/login")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            escaped_user = html.escape(user)
            body = PORTAL_HTML_TEMPLATE.replace("__USER_ESCAPED__", escaped_user).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.add_security_headers()
            self.end_headers()
            self.wfile.write(body)
            return

        # Page non trouvée
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"404 Not Found")

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        client_ip = self.get_client_ip()

        if path != "/login" and path != "/login/":
            self.send_response(404)
            self.end_headers()
            return

        # Vérification Rate Limit
        if is_rate_limited(client_ip):
            self.send_response(302)
            self.send_header("Location", "/login?error=rate_limited")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # Délai anti-timing & anti-bot
        time.sleep(0.3)

        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length).decode("utf-8", errors="ignore")
        form_data = urllib.parse.parse_qs(post_data)

        username = form_data.get("username", [""])[0].strip()
        password = form_data.get("password", [""])[0]

        users = load_users()
        user_record = users.get(username)

        if user_record and verify_password(user_record, password):
            # Succès ! Réinitialiser les échecs
            reset_failed_attempts(client_ip)
            # Générer un session ID sécurisé (256 bits d'entropie)
            session_id = secrets.token_urlsafe(32)
            now = time.time()
            with sessions_lock:
                sessions[session_id] = {
                    "user": username,
                    "created_at": now,
                    "last_seen": now
                }
            self.send_response(302)
            self.send_header("Location", "/portal")
            # Cookie de session : pas de Max-Age fixe (détruit quand le navigateur est fermé)
            self.send_header("Set-Cookie", f"{COOKIE_NAME}={session_id}; Path=/; HttpOnly; SameSite=Strict; Secure")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        else:
            # Échec
            record_failed_attempt(client_ip)
            self.send_response(302)
            self.send_header("Location", "/login?error=invalid")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return


def run_server():
    server_address = ("0.0.0.0", LISTEN_PORT)
    httpd = http.server.ThreadingHTTPServer(server_address, AuthGatewayHandler)
    print(f"[AUTH PORTAL] Démarrage sur le port {LISTEN_PORT}...")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    run_server()
