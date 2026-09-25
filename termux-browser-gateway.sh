#!/data/data/com.termux/files/usr/bin/bash
#
# Passerelle navigateur distante pour Termux/Android.
#
# Cette version est volontairement limitée à UNE session Chromium partagée.
# Elle ne crée pas un proxy TCP ouvert : les amis contrôlent un navigateur
# distant protégé par authentification HTTP.
#
# Architecture :
#   Chromium dans Debian/proot-distro -> Xvfb -> x11vnc -> noVNC
#   -> Nginx avec authentification -> Cloudflare Quick Tunnel
#
# Le tunnel donne une URL publique temporaire. Pour une URL stable, il faudra
# remplacer le Quick Tunnel par un tunnel Cloudflare nommé.

set -Eeuo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BASE="$PREFIX/var/lib/claude-browser-gateway"
NGINX_CONF="$BASE/nginx.conf"
AUTH_FILE="$BASE/htpasswd"
USERNAME_FILE="$BASE/username"

info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ATTENTION]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; }

require_termux() {
    if [ "${PREFIX:-}" = "" ] || [ ! -d "$PREFIX" ]; then
        error "Ce script doit être exécuté dans Termux."
        exit 1
    fi
}

install_dependencies() {
    info "Mise à jour des paquets Termux..."
    pkg update -y
    pkg upgrade -y
    pkg install -y curl nginx openssl-tool cloudflared proot-distro

    if ! proot-distro login --shared-tmp debian -- true >/dev/null 2>&1; then
        info "Installation de Debian dans proot-distro..."
        proot-distro install debian
    fi

    info "Installation du navigateur et de noVNC dans Debian..."
    proot-distro login --shared-tmp debian -- bash -lc '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends \
            ca-certificates chromium xvfb x11vnc novnc websockify procps
    '

    mkdir -p "$BASE"
    chmod 700 "$BASE"
    info "Dépendances installées."
}

ensure_dependencies() {
    if ! command -v curl >/dev/null 2>&1 || \
       ! command -v nginx >/dev/null 2>&1 || \
       ! command -v openssl >/dev/null 2>&1 || \
       ! command -v cloudflared >/dev/null 2>&1 || \
       ! command -v proot-distro >/dev/null 2>&1 || \
       ! proot-distro login --shared-tmp debian -- true >/dev/null 2>&1; then
        install_dependencies
    fi
}

setup_auth() {
    mkdir -p "$BASE"
    chmod 700 "$BASE"

    if [ -f "$AUTH_FILE" ] && [ -f "$USERNAME_FILE" ]; then
        info "Authentification déjà configurée pour l'utilisateur : $(cat "$USERNAME_FILE")"
        return
    fi

    printf '\n'
    printf "Création de l'accès privé au navigateur distant.\n"
    read -r -p "Nom d'utilisateur de la passerelle [ami] : " user
    user="${user:-ami}"

    while true; do
        read -r -s -p 'Mot de passe de la passerelle : ' password
        printf '\n'
        read -r -s -p 'Répète le mot de passe : ' password2
        printf '\n'
        if [ -z "$password" ]; then
            warn "Le mot de passe ne peut pas être vide."
        elif [ "$password" != "$password2" ]; then
            warn "Les mots de passe ne correspondent pas."
        elif [ "${#password}" -lt 16 ]; then
            warn "Utilise au moins 16 caractères."
        else
            break
        fi
    done

    hash="$(printf '%s' "$password" | openssl passwd -apr1 -stdin)"
    printf '%s:%s\n' "$user" "$hash" > "$AUTH_FILE"
    printf '%s\n' "$user" > "$USERNAME_FILE"
    chmod 600 "$AUTH_FILE" "$USERNAME_FILE"
    unset password password2 hash

    info "Authentification enregistrée localement dans $BASE."
}

write_nginx_config() {
    mkdir -p "$BASE"
    cat > "$NGINX_CONF" <<EOF
pid $BASE/nginx.pid;
error_log $BASE/nginx-error.log;

events {}

http {
    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        '' close;
    }

    server {
        listen 8081;
        server_name _;

        auth_basic "Private browser";
        auth_basic_user_file $AUTH_FILE;

        location / {
            proxy_pass http://127.0.0.1:6080;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_buffering off;
        }
    }
}
EOF
    chmod 600 "$NGINX_CONF"
}

start_browser() {
    info "Arrêt des anciennes sessions éventuelles..."
    # Les processus lancés dans un proot sont arrêtés lorsque la session
    # proot se termine. On garde donc une session détachée vivante avec
    # sleep, puis on lance Chromium/noVNC à l'intérieur.
    proot-distro kill debian >/dev/null 2>&1 || true

    info "Démarrage de Chromium, de l'écran virtuel et de noVNC..."
    proot-distro login --shared-tmp --detach debian -- bash -lc '
        set -u
        mkdir -p /root/claude-browser-logs /root/claude-gateway-profile

        Xvfb :99 -screen 0 1280x800x24 -ac +extension RANDR \
            > /root/claude-browser-logs/xvfb.log 2>&1 &
        sleep 2

        export DISPLAY=:99
        browser="$(command -v chromium || command -v chromium-browser)"
        "$browser" \
            --no-sandbox \
            --disable-setuid-sandbox \
            --disable-dev-shm-usage \
            --disable-gpu \
            --no-first-run \
            --no-default-browser-check \
            --user-data-dir=/root/claude-gateway-profile \
            --window-size=1280,800 \
            --start-maximized \
            https://claude.ai \
            > /root/claude-browser-logs/chromium.log 2>&1 &

        sleep 3
        x11vnc \
            -display :99 \
            -localhost \
            -forever \
            -shared \
            -nopw \
            -rfbport 5900 \
            -noxdamage \
            > /root/claude-browser-logs/x11vnc.log 2>&1 &

        sleep 2
        if [ -x /usr/share/novnc/utils/novnc_proxy ]; then
            /usr/share/novnc/utils/novnc_proxy \
                --vnc localhost:5900 \
                --listen 6080 \
                > /root/claude-browser-logs/novnc.log 2>&1 &
        else
            websockify --web=/usr/share/novnc 6080 localhost:5900 \
                > /root/claude-browser-logs/novnc.log 2>&1 &
        fi

        # Maintient la session proot en vie afin que les processus graphiques
        # ne reçoivent pas SIGTERM dès la fin de la commande d installation.
        exec sleep 2147483647
    '

    sleep 5
    if ! curl -fsS http://127.0.0.1:6080/ >/dev/null 2>&1; then
        warn "noVNC ne répond pas encore. Consulte les journaux dans Debian :"
        warn "proot-distro login debian -- bash -lc 'cat /root/claude-browser-logs/*.log'"
        return 1
    fi
}

start_nginx() {
    write_nginx_config
    nginx -s stop -c "$NGINX_CONF" -p "$PREFIX" >/dev/null 2>&1 || true
    nginx -t -c "$NGINX_CONF" -p "$PREFIX"
    nginx -c "$NGINX_CONF" -p "$PREFIX"
}

stop_all() {
    info "Arrêt de la passerelle..."
    nginx -s stop -c "$NGINX_CONF" -p "$PREFIX" >/dev/null 2>&1 || true
    # Tue la session proot détachée et tous ses processus enfants.
    proot-distro kill debian >/dev/null 2>&1 || true
    termux-wake-unlock >/dev/null 2>&1 || true
}

start_all() {
    require_termux
    ensure_dependencies
    setup_auth
    start_browser
    start_nginx
    termux-wake-lock >/dev/null 2>&1 || true

    printf '\n'
    info "Le navigateur distant est prêt."
    info "Lancement du tunnel HTTPS temporaire..."
    warn "Garde Termux ouvert et désactive l'optimisation batterie pour Termux."
    warn "L'URL affichée par cloudflared changera au prochain démarrage."
    printf '\n'

    trap stop_all EXIT INT TERM
    cloudflared tunnel --url http://127.0.0.1:8081
}

show_status() {
    printf 'Dossier : %s\n' "$BASE"
    if [ -f "$USERNAME_FILE" ]; then
        printf 'Utilisateur passerelle : %s\n' "$(cat "$USERNAME_FILE")"
    else
        printf 'Authentification : non configurée\n'
    fi
    printf '\nConteneur Debian :\n'
    proot-distro login --shared-tmp debian -- bash -lc \
        'pgrep -af "Xvfb|chromium|x11vnc|novnc_proxy" || true'
    printf '\nNginx :\n'
    pgrep -af "nginx.*claude-browser-gateway" || true
}

usage() {
    cat <<EOF
Usage: $0 [commande]

Commandes :
  install    installe Debian, Chromium, noVNC, Nginx et cloudflared
  start      démarre le navigateur et le tunnel HTTPS temporaire
  stop       arrête le navigateur et Nginx
  status     affiche l'état de la passerelle
  reset-auth recrée l'utilisateur et le mot de passe

Exemple :
  $0 install
  $0 start
EOF
}

main() {
    require_termux
    command="${1:-start}"
    case "$command" in
        install)
            install_dependencies
            setup_auth
            write_nginx_config
            ;;
        start)
            start_all
            ;;
        stop)
            stop_all
            ;;
        status)
            show_status
            ;;
        reset-auth)
            rm -f "$AUTH_FILE" "$USERNAME_FILE"
            setup_auth
            write_nginx_config
            ;;
        -h|--help|help)
            usage
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
