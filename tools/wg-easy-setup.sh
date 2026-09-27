#!/usr/bin/env bash
#
# wg-easy-setup.sh - WireGuard-Server (wg-easy) im Buero einrichten und pruefen
#
# Bringt ein Smartphone per VPN ins Buero-LAN, auch wenn die FRITZ!Box selbst kein
# WireGuard kann (FRITZ!OS vor 7.50). wg-easy laeuft als Docker-Container auf einem
# Linux-Rechner im Buero, die FRITZ!Box leitet nur UDP 51820 dorthin weiter.
#
#   Smartphone --UDP 51820--> FRITZ!Box --> dieser Rechner (wg-easy) --> Buero-LAN
#
# Umgesetzt und geprueft wird:
#   - UDP 51820 antwortet nur Geraeten mit gueltigem Schluessel. Fremden gegenueber
#     bleibt der Port stumm; das Skript schickt ein Zufallspaket und erwartet Stille.
#   - Die Weboberflaeche (TCP 51821) lauscht nur auf 127.0.0.1 dieses Rechners und
#     wird per SSH-Tunnel bedient. Sie wird nie ins LAN oder Internet freigegeben.
#   - Das Admin-Konto bekommt 2FA (TOTP), --check meldet, ob sie aktiv ist.
#
# Verwendung, als root:
#   sudo bash wg-easy-setup.sh           installieren bzw. aktualisieren, dann pruefen
#   sudo bash wg-easy-setup.sh --check   nur pruefen, aendert nichts
#   sudo bash wg-easy-setup.sh --remove  Container entfernen, Schluessel bleiben erhalten
#
# WG_EASY_IMAGE ueberschreibt das Image, etwa fuer eine feste Version:
#   sudo WG_EASY_IMAGE=ghcr.io/wg-easy/wg-easy:15.4.0 bash wg-easy-setup.sh
#
# Grundlage ist die offizielle docker-compose.yml von wg-easy v15.4.0 mit zwei
# Abweichungen: INSECURE=true (HTTP statt HTTPS) und Weboberflaeche nur auf 127.0.0.1.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Bitte mit bash starten:  sudo bash $0" >&2
    exit 1
fi

set -u -o pipefail

NAME='wg-easy'
DIR=/etc/docker/containers/wg-easy
IMAGE=${WG_EASY_IMAGE:-ghcr.io/wg-easy/wg-easy:15}
SELF=${BASH_SOURCE[0]:-}
[ -f "$SELF" ] || SELF='wg-easy-setup.sh'
WG_PORT=51820
UI_PORT=51821
CLOSED_PORT=51899    # Gegenprobe: auf diesem Port lauscht im Container nichts
COMPOSE=()
LOGIN_DONE=0         # 1, sobald Einrichtung fertig und jedes Konto 2FA hat
SILENCE_OK=0         # 1, sobald UDP 51820 nachweislich stumm geblieben ist

# Ohne IPv6 im Kernel scheitert das IPv6-Netz der Vorlage; dann nur IPv4 (reicht fuers LAN).
IPV6=0
[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 0 ] && IPV6=1

if [ -t 1 ]; then
    C_HEAD=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_BAD=$'\e[31m' C_OFF=$'\e[0m'
else
    C_HEAD='' C_OK='' C_WARN='' C_BAD='' C_OFF=''
fi

section() { printf '\n%s== %s ==%s\n' "$C_HEAD" "$1" "$C_OFF"; }
ok()      { printf '  %s[ok]%s   %s\n' "$C_OK" "$C_OFF" "$1"; }
warn()    { printf '  %s[!]%s    %s\n' "$C_WARN" "$C_OFF" "$1"; }
bad()     { printf '  %s[FEHLER]%s %s\n' "$C_BAD" "$C_OFF" "$1"; }
info()    { printf '  %s\n' "$1"; }
detail()  { printf '         %s\n' "$1"; }
die()     { bad "$1"; exit 1; }

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        COMPOSE=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE=(docker-compose)
    else
        return 1
    fi
}

compose() { (cd "$DIR" && "${COMPOSE[@]}" "$@"); }

listen_port() { docker exec "$NAME" wg show wg0 listen-port 2>/dev/null | tr -d '[:space:]'; }

# Wer belegt proto/port auf diesem Rechner? Leere Ausgabe heisst frei.
port_in_use() {
    local proto=$1 port=$2 flags=-Hltnp hit
    hit=$(docker ps --filter "publish=$port/$proto" --format '{{.Names}}' | head -n 1)
    if [ -n "$hit" ]; then
        printf 'Container %s' "$hit"
        return
    fi
    command -v ss >/dev/null 2>&1 || return 0
    [ "$proto" = udp ] && flags=-Hlunp
    hit=$(ss "$flags" "sport = :$port" 2>/dev/null | head -n 1)
    [ -n "$hit" ] || return 0
    sed -n 's/.*users:(("\([^"]*\)",pid=\([0-9]*\).*/Programm \1 (PID \2)/p' <<< "$hit" | grep . ||
        printf '%s' "$hit"
}

# Schickt 148 Zufallsbytes (Groesse einer WireGuard-Handshake-Anfrage) an host:port.
# Ausgabe: reply (Antwort kam), silent (3 s Stille), refused (Port geschlossen), error.
probe_udp() {
    local rc=0
    bash -c '
        exec 3<>"/dev/udp/$0/$1" || exit 90
        head -c 148 /dev/urandom >&3 || exit 91
        timeout 3 head -c 1 <&3 >/dev/null
    ' "$1" "$2" 2>/dev/null || rc=$?
    case $rc in
        0)   echo reply ;;
        124) echo silent ;;
        1)   echo refused ;;
        *)   echo error ;;
    esac
}

lan_ip() {
    local ip=''
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null |
             awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
    fi
    [ -n "$ip" ] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    printf '%s' "${ip:-<IP-dieses-Rechners>}"
}

compose_file() {
    cat <<EOF
# Erzeugt von wg-easy-setup.sh - Aenderungen werden beim naechsten Lauf gesichert
# und ersetzt. Grundlage: offizielle docker-compose.yml von wg-easy v15.4.0.
# Abweichungen: INSECURE=true und Weboberflaeche nur auf 127.0.0.1. Port $UI_PORT
# nie freigeben, die Oberflaeche per SSH-Tunnel bedienen.
volumes:
  etc_wireguard:

services:
  wg-easy:
    environment:
      - INSECURE=true
EOF
    if [ "$IPV6" = 0 ]; then
        echo '      - DISABLE_IPV6=true'
    fi
    cat <<EOF
    image: $IMAGE
    container_name: $NAME
    networks:
      wg:
        ipv4_address: 10.42.42.42
EOF
    if [ "$IPV6" = 1 ]; then
        echo '        ipv6_address: fdcc:ad94:bacf:61a3::2a'
    fi
    cat <<EOF
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "$WG_PORT:51820/udp"
      - "127.0.0.1:$UI_PORT:51821/tcp"
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF
    if [ "$IPV6" = 1 ]; then
        cat <<'EOF'
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1
EOF
    fi
    cat <<'EOF'

networks:
  wg:
    driver: bridge
EOF
    if [ "$IPV6" = 1 ]; then
        echo '    enable_ipv6: true'
    fi
    cat <<'EOF'
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
EOF
    if [ "$IPV6" = 1 ]; then
        echo '        - subnet: fdcc:ad94:bacf:61a3::/64'
    fi
}

# ---------------------------------------------------------------- Installation
preflight() {
    section 'Voraussetzungen'
    [ "$(uname -s)" = Linux ] || die 'Nur fuer Linux.'
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        die 'Das ist WSL. Eine Portfreigabe der FRITZ!Box erreicht WSL nicht - bitte direkt auf einem Linux-Rechner ausfuehren.'
    fi
    ok "Linux, Kernel $(uname -r)"

    docker info >/dev/null 2>&1 || die 'Docker-Dienst nicht erreichbar (systemctl status docker).'
    detect_compose || die 'Docker Compose fehlt (Paket docker-compose-plugin).'
    ok "Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null), ${COMPOSE[*]}"

    if modinfo wireguard >/dev/null 2>&1 || [ -d /sys/module/wireguard ]; then
        ok 'Kernel hat WireGuard'
    else
        warn 'WireGuard-Modul nicht gefunden. Ab Kernel 5.6 ist es meist eingebaut;'
        detail 'startet wg-easy trotzdem nicht, zeigt der Start unten die Ursache.'
    fi
    if [ "$IPV6" = 1 ]; then
        ok 'IPv6 vorhanden'
    else
        warn 'IPv6 ist im Kernel aus. wg-easy laeuft dann nur mit IPv4, das reicht fuers Buero-LAN.'
    fi

    if docker inspect "$NAME" >/dev/null 2>&1; then
        local wd
        wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$NAME")
        [ "$wd" = '<no value>' ] && wd=''
        [ "$wd" = "$DIR" ] ||
            die "Es gibt schon einen Container '$NAME' aus einer anderen Einrichtung (${wd:-ohne Compose}). Bitte zuerst dort entfernen."
        ok "Container '$NAME' ist schon da und wird aktualisiert"
        return
    fi

    local proto port hit
    for proto in udp tcp; do
        port=$WG_PORT
        [ "$proto" = tcp ] && port=$UI_PORT
        hit=$(port_in_use "$proto" "$port")
        [ -z "$hit" ] || die "Port $port/$proto ist schon belegt: $hit"
    done
    ok "Ports $WG_PORT/udp und $UI_PORT/tcp sind frei"
}

write_compose() {
    section 'Konfiguration'
    mkdir -p "$DIR" || die "$DIR laesst sich nicht anlegen."
    local file=$DIR/docker-compose.yml tmp backup
    tmp=$(mktemp) || die 'mktemp fehlgeschlagen.'
    compose_file > "$tmp"
    if [ -f "$file" ] && ! cmp -s "$tmp" "$file"; then
        backup=$file.bak-$(date +%Y%m%d-%H%M%S)
        cp -p "$file" "$backup"
        warn "Bisherige Datei gesichert: $backup"
    fi
    install -m 644 "$tmp" "$file"
    rm -f "$tmp"
    ok "$file"
}

start_container() {
    section 'Container starten'
    if ! compose pull; then
        docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE laesst sich nicht laden."
        warn "Download fehlgeschlagen, nehme das vorhandene Image $IMAGE."
    fi
    compose up -d || die 'docker compose up ist fehlgeschlagen (Meldung oben).'

    local _
    for _ in $(seq 1 30); do
        if [ "$(listen_port)" = "$WG_PORT" ]; then
            ok "Container '$NAME' laeuft"
            return
        fi
        sleep 2
    done
    bad 'WireGuard kommt nicht hoch. Letzte Zeilen aus dem Container-Log:'
    docker logs --tail 20 "$NAME" 2>&1 | sed 's/^/    /'
    exit 1
}

# ---------------------------------------------------------------- Pruefung
check_silence() {
    local ip wg ref
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$NAME" |
         awk '{print $1}')
    if [ -z "$ip" ]; then
        warn 'Container-IP unbekannt, Stummtest uebersprungen.'
        return 0
    fi

    wg=$(probe_udp "$ip" 51820)
    ref=$(probe_udp "$ip" "$CLOSED_PORT")
    case $wg in
        silent)
            SILENCE_OK=1
            if [ "$ref" = refused ]; then
                ok "UDP $WG_PORT antwortet Fremden nicht"
                detail "(Zufallspaket ohne Antwort, Gegenprobe: geschlossener Port $CLOSED_PORT meldet sich)"
            else
                warn "UDP $WG_PORT bleibt stumm, die Gegenprobe ist aber nicht eindeutig ($ref)."
            fi ;;
        reply)
            bad "UDP $WG_PORT antwortet auf ein Zufallspaket. So verhaelt sich WireGuard nicht."
            return 1 ;;
        refused)
            bad "Auf UDP $WG_PORT lauscht im Container nichts."
            return 1 ;;
        *)
            warn 'Stummtest nicht moeglich (bash ohne /dev/udp?).' ;;
    esac
    return 0
}

# Liest Einrichtungsstand und 2FA aus der wg-easy-Datenbank (nur lesend).
# Fehlschlag nur, wenn die Einrichtung fertig ist und ein Konto ohne 2FA existiert.
check_login() {
    local src db rows step kind totp name with='' without=''
    src=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/wireguard"}}{{.Source}}{{end}}{{end}}' "$NAME")
    db=$src/wg-easy.db
    if [ -z "$src" ] || [ ! -f "$db" ]; then
        warn '2FA-Status nicht lesbar (Datenbank fehlt), bitte in der Weboberflaeche pruefen.'
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        rows=$(python3 - "$db" 2>/dev/null <<'PY'
import sqlite3, sys
con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
row = con.execute("SELECT setup_step FROM general_table WHERE id = 1").fetchone()
print("setup", row[0] if row else "-")
for name, totp in con.execute("SELECT username, totp_verified FROM users_table"):
    print("user", int(bool(totp)), name)
PY
)
    elif command -v sqlite3 >/dev/null 2>&1; then
        rows=$(sqlite3 -readonly -separator ' ' "$db" \
            "SELECT 'setup', setup_step FROM general_table WHERE id = 1;
             SELECT 'user', totp_verified, username FROM users_table;" 2>/dev/null)
    else
        warn '2FA-Status nicht pruefbar (python3 oder sqlite3 fehlt), bitte in der Weboberflaeche pruefen.'
        return 0
    fi

    if [ -z "$rows" ]; then
        warn '2FA-Status nicht lesbar, bitte in der Weboberflaeche pruefen.'
        return 0
    fi
    step=$(awk '$1 == "setup" {print $2}' <<< "$rows")
    if [ "$step" != 0 ]; then
        warn 'Einrichtung in der Weboberflaeche ist noch offen, 2FA damit auch.'
        return 0
    fi
    while read -r kind totp name; do
        [ "$kind" = user ] || continue
        if [ "$totp" = 1 ]; then with+=" $name"; else without+=" $name"; fi
    done <<< "$rows"
    [ -z "$with" ] || ok "2FA aktiv fuer:$with"
    if [ -n "$without" ]; then
        bad "2FA noch nicht aktiv fuer:$without"
        return 1
    fi
    [ -z "$with" ] || LOGIN_DONE=1
    return 0
}

run_checks() {
    section 'Pruefung'
    local failed=0 port ui

    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" != true ]; then
        bad "Container '$NAME' laeuft nicht."
        return 1
    fi
    ok "Container '$NAME' laeuft ($(docker inspect -f '{{.Config.Image}}' "$NAME"))"

    port=$(listen_port)
    if [ "$port" = "$WG_PORT" ]; then
        ok "WireGuard lauscht auf UDP $WG_PORT"
    else
        bad "WireGuard lauscht nicht auf UDP $WG_PORT (gemeldet: ${port:-nichts})."
        detail "In der Weboberflaeche muss als Port $WG_PORT eingetragen sein."
        failed=1
    fi

    ui=$(docker port "$NAME" 51821/tcp 2>/dev/null)
    if [ -n "$ui" ] && ! grep -qv '^127\.0\.0\.1:' <<< "$ui"; then
        ok "Weboberflaeche nur auf diesem Rechner erreichbar ($ui)"
    else
        bad "Weboberflaeche nicht auf 127.0.0.1 beschraenkt: ${ui:-keine Portzuordnung}"
        failed=1
    fi

    check_silence || failed=1
    check_login || failed=1
    return "$failed"
}

next_steps() {
    local ip user
    ip=$(lan_ip)
    user=${SUDO_USER:-benutzer}
    section 'Naechste Schritte von Hand'
    info "1. Weboberflaeche oeffnen. Von einem Buero-PC per SSH-Tunnel:"
    info "     ssh -L $UI_PORT:127.0.0.1:$UI_PORT $user@$ip"
    info "   dann dort im Browser http://localhost:$UI_PORT (direkt an diesem Rechner genauso)."
    info "2. Einrichtung: Admin-Benutzer und Passwort anlegen, bestehende Konfiguration: No,"
    info "   Host = MyFRITZ!-Adresse der Box (....myfritz.net), Port = $WG_PORT."
    info "3. 2FA: Menue oben rechts > Konto (Account) > Zwei-Faktor-Authentifizierung,"
    info "   QR-Code mit einer Authenticator-App scannen, Code bestaetigen."
    info "4. FRITZ!Box: Internet > Freigaben > Portfreigaben > Geraet fuer Freigaben hinzufuegen"
    info "   > $ip > Neue Freigabe > Portfreigabe > UDP, Port $WG_PORT. Nichts sonst freigeben."
    info "   Unter Heimnetz > Netzwerk bei diesem Rechner 'immer die gleiche IPv4-Adresse' setzen."
    info "   Empfohlen: Internet > Filter > Listen > Globale Filtereinstellungen >"
    info "   'Firewall im Stealth Mode', dann schweigen auch alle anderen Ports."
    info "5. In der Weboberflaeche einen Client fuer das Smartphone anlegen und den QR-Code"
    info "   in der WireGuard-App scannen (+ > Von QR-Code scannen)."
    info "6. Zum Schluss pruefen:  sudo bash $SELF --check"
}

remove_container() {
    section 'Entfernen'
    if [ -f "$DIR/docker-compose.yml" ] && detect_compose; then
        compose down || die 'docker compose down ist fehlgeschlagen.'
    else
        docker rm -f "$NAME" >/dev/null 2>&1
    fi
    ok "Container '$NAME' entfernt. Schluessel und Einstellungen liegen weiter im Docker-Volume."
    info "Endgueltig loeschen, alle VPN-Zugaenge werden ungueltig:  docker volume rm wg-easy_etc_wireguard"
    info "Die Portfreigabe UDP $WG_PORT in der FRITZ!Box ebenfalls entfernen."
}

main() {
    local mode=install rc
    case ${1:-} in
        '')        ;;
        --check)   mode=check ;;
        --remove)  mode=remove ;;
        -h|--help) sed -n '3,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         die "Unbekannte Option '$1' (erlaubt: --check, --remove, --help)." ;;
    esac
    [ "$(id -u)" -eq 0 ] || die 'Bitte mit sudo starten.'
    command -v docker >/dev/null 2>&1 || die 'Docker fehlt, Installation: https://docs.docker.com/engine/install/'

    case $mode in
        install)
            preflight
            write_compose
            start_container
            run_checks
            rc=$?
            if [ "$rc" -eq 0 ] && [ "$LOGIN_DONE" = 1 ] && [ "$SILENCE_OK" = 1 ]; then
                section 'Ergebnis'
                ok 'Alles eingerichtet. Pruefen jederzeit mit --check.'
            else
                next_steps
            fi
            exit "$rc" ;;
        check)
            run_checks
            rc=$?
            section 'Ergebnis'
            if [ "$rc" -eq 0 ] && [ "$LOGIN_DONE" = 1 ] && [ "$SILENCE_OK" = 1 ]; then
                ok 'Alles in Ordnung.'
            elif [ "$rc" -eq 0 ]; then
                warn 'Technik in Ordnung, aber Einrichtung, 2FA oder Stummtest offen bzw. nicht pruefbar.'
                next_steps
            else
                bad 'Offene Punkte siehe oben.'
                next_steps
            fi
            exit "$rc" ;;
        remove)
            remove_container ;;
    esac
}

main "$@"
