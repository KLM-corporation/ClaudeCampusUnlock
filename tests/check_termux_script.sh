#!/usr/bin/env bash
# Verifications statiques de termux-browser-gateway.sh (aucun Termux requis).
# Lancer depuis la racine du depot : bash tests/check_termux_script.sh
set -u
script="${1:-termux-browser-gateway.sh}"
fail=0

check() { # check <description> <fonction ou commande qui doit reussir>
    if "${@:2}"; then printf 'ok   %s\n' "$1"; else printf 'FAIL %s\n' "$1"; fail=1; fi
}

nginx_local_only() {
    grep -qE '^[[:space:]]*listen 127\.0\.0\.1:8081;' "$script" && ! grep -qE '^[[:space:]]*listen 8081;' "$script"
}
novnc_local_only() {
    grep -qE -- '--listen 127\.0\.0\.1:6080' "$script" && ! grep -qE -- '--listen 6080' "$script"
}
websockify_local_only() {
    grep -qE 'websockify --web=[^ ]+ 127\.0\.0\.1:6080' "$script"
}
x11vnc_local_only() {
    grep -qE -- '-localhost' "$script"
}
trap_before_start_browser() {
    awk '/^start_all\(\)/,/^}/' "$script" \
        | awk '/trap stop_all/{t=NR} /^    start_browser/{b=NR} END{exit !(t && b && t<b)}'
}
# Les blocs passes a "bash -lc" sont entre apostrophes simples : une apostrophe dans un
# commentaire ferme la chaine et casse le script au lancement.
no_apostrophe_in_proot_blocks() {
    local n
    n=$(awk '/bash -lc \047$/{f=1; next} f && /^    \047$/{f=0} f' "$script" | grep -c "'")
    [ "$n" -eq 0 ]
}

check "syntaxe bash valide" bash -n "$script"
check "nginx n'ecoute que sur 127.0.0.1" nginx_local_only
check "novnc_proxy lie a 127.0.0.1" novnc_local_only
check "repli websockify lie a 127.0.0.1" websockify_local_only
check "x11vnc reste en -localhost" x11vnc_local_only
check "trap de nettoyage installe avant start_browser" trap_before_start_browser
check "pas d'apostrophe dans les blocs proot-distro" no_apostrophe_in_proot_blocks

exit "$fail"
