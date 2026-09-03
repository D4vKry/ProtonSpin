#!/bin/bash

# ---
# ProtonSpin
# 
# Made by D4vKry
# Last update 2/9/2026
# Website: https://d4vkry.github.io
# Thanks ;)
#
# Requirements:
#   - root
#   - ufw
#   - openvpn
#   - curl
#   - ip
#   - awk
#   - grep
#   - sed
#   - realpath
#   - getent
#   - stat
#   - flock
# ---

set -u
set -o pipefail

# ---
# USER CONFIG
# ---

FOLDER_VPNS="./proton"
FILE_AUTH="./proton/creds.txt"
TEMPO=360

# public IP service for connectivity test.
IP_CHECK_URLS=(
    "https://ifconfig.me"
    "https://api.ipify.org"
    "https://icanhazip.com"
)

# ---
# SYSTEM CONFIG
# ---

STATE_DIR="/run/openvpn-rotator"
PID_FILE="$STATE_DIR/openvpn.pid"
LOCK_FILE="$STATE_DIR/rotator.lock"
UFW_BACKUP="$STATE_DIR/ufw.state"
DNS_BACKUP="$STATE_DIR/resolv.conf"
LOG_FILE="/var/log/openvpn_rotation.log"

TUN_DEV="tun-rotator"

UFW_FAMILY="ovpn-rot"
UFW_TAG="${UFW_FAMILY}-$$"

# ---
# RUNTIME STATE
# ---

CLEANED_UP=false

UFW_BACKED_UP=false
UFW_MODIFIED=false
IPV6_MODIFIED=false

DNS_BACKED_UP=false
DNS_MODIFIED=false
USING_RESOLVECTL=false

VPN_ACTIVE=false

ORIGINAL_UFW_STATUS=""
ORIGINAL_UFW_IN=""
ORIGINAL_UFW_OUT=""
ORIGINAL_IPV6_ALL=""
ORIGINAL_IPV6_DEF=""

CURRENT_CONFIG=""

# ---
# LOGGING
# ---

log() {
    local level="$1"
    shift

    printf '[%(%H:%M:%S)T] [%s] %s\n' -1 "$level" "$*" \
        | tee -a "$LOG_FILE"
}

die() {
    log "!" "$*"
    exit 1
}

# ---
# CHECKS
# ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "[!] please run this script as root (sudo)."
        exit 1
    fi
}

check_dependencies() {
    local deps=(
        ufw
        openvpn
        curl
        ip
        awk
        grep
        sed
        realpath
        getent
        stat
        flock
    )

    local cmd

    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "missing dependency: $cmd"
        fi
    done
}

# ---
# LOCK
# ---

acquire_lock() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
        die "another instance of the rotator is already running"
    fi
}

# ---
# VALIDATE
# ---

validate_environment() {

    [[ "$TEMPO" =~ ^[1-9][0-9]*$ ]] \
        || die "TEMPO must be a positive integer"

    [ -d "$FOLDER_VPNS" ] \
        || die "VPN directory does not exist: $FOLDER_VPNS"

    [ -f "$FILE_AUTH" ] \
        || die "credentials file does not exist: $FILE_AUTH"

    local perms
    perms=$(stat -c "%a" "$FILE_AUTH" 2>/dev/null || echo "000")

    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        die "credentials file must have permissions 600 or 400"
    fi

    if [ -f "$UFW_BACKUP" ] || [ -f "$DNS_BACKUP" ]; then
        echo "[!] stale state detected."
        echo "[i] run: sudo $0 --reset"
        exit 1
    fi
}

# ---
# DNS
# ---

backup_dns() {

    if command -v resolvectl >/dev/null 2>&1 \
        && systemctl is-active --quiet systemd-resolved 2>/dev/null; then

        USING_RESOLVECTL=true
        DNS_MODIFIED=true

        log "+" "systemd-resolved detected"

        return 0
    fi

    USING_RESOLVECTL=false

    if ! cp --preserve=mode,ownership,timestamps \
        /etc/resolv.conf "$DNS_BACKUP" 2>/dev/null; then

        die "unable to backup /etc/resolv.conf"
    fi

    DNS_BACKED_UP=true
    DNS_MODIFIED=true

    log "+" "DNS configuration backed up"
}

configure_dns() {

    if [ "$USING_RESOLVECTL" = true ]; then
        return 0
    fi

    if ! printf '%s\n' \
        "nameserver 9.9.9.9" \
        "nameserver 1.1.1.1" \
        > /etc/resolv.conf; then

        die "unable to configure /etc/resolv.conf"
    fi

    log "+" "temporary DNS configuration applied"
}

configure_tunnel_dns() {

    if [ "$USING_RESOLVECTL" != true ]; then
        return 0
    fi

    if ! resolvectl dns "$TUN_DEV" 9.9.9.9 1.1.1.1 \
        >/dev/null 2>&1; then

        log "!" "failed to configure DNS servers on $TUN_DEV"
        return 1
    fi

    if ! resolvectl domain "$TUN_DEV" '~.' \
        >/dev/null 2>&1; then

        log "!" "failed to configure DNS routing on $TUN_DEV"
        return 1
    fi

    log "+" "DNS routed through $TUN_DEV"
}

restore_dns() {

    [ "$DNS_MODIFIED" = true ] || return 0

    if [ "$USING_RESOLVECTL" = true ]; then
        return 0
    fi

    if [ "$DNS_BACKED_UP" = true ] && [ -f "$DNS_BACKUP" ]; then

    if cat "$DNS_BACKUP" > /etc/resolv.conf 2>/dev/null; then
            rm -f "$DNS_BACKUP"
            log "+" "original DNS configuration restored"
        else
            log "!" "FAILED to restore /etc/resolv.conf"
        fi
    fi
}

ufw_rules_with_tag() {
    ufw status numbered \
        | grep "$UFW_TAG" \
        | awk -F'[][]' '{print $2}' \
        | sort -nr || true
}

ufw_remove_instance_rules() {

    local numbers
    numbers=$(ufw_rules_with_tag)

    [ -n "$numbers" ] || return 0

    local number

    while read -r number; do
        [ -n "$number" ] || continue
        yes | ufw delete "$number" >/dev/null 2>&1 || true
    done <<< "$numbers"
}

# ---
# UFW BACKUP
# ---

backup_ufw() {

    local status
    local incoming
    local outgoing

    if ufw status | grep -qi "Status: active"; then
        status="active"
    else
        status="inactive"
    fi

    incoming=$(
        LC_ALL=C ufw status verbose \
        | grep "Default:" \
        | grep -o \
        'allow (incoming)\|deny (incoming)\|reject (incoming)' \
        | awk '{print $1}' \
        || true
    )

    outgoing=$(
        LC_ALL=C ufw status verbose \
        | grep "Default:" \
        | grep -o \
        'allow (outgoing)\|deny (outgoing)\|reject (outgoing)' \
        | awk '{print $1}' \
        || true
    )

    incoming=${incoming:-deny}
    outgoing=${outgoing:-allow}

    ORIGINAL_UFW_STATUS="$status"
    ORIGINAL_UFW_IN="$incoming"
    ORIGINAL_UFW_OUT="$outgoing"
    
    ORIGINAL_IPV6_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)
    ORIGINAL_IPV6_DEF=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 0)

    {
        printf 'status=%s\n' "$status"
        printf 'incoming=%s\n' "$incoming"
        printf 'outgoing=%s\n' "$outgoing"
        printf 'ipv6_all=%s\n' "$ORIGINAL_IPV6_ALL"
        printf 'ipv6_def=%s\n' "$ORIGINAL_IPV6_DEF"
    } > "$UFW_BACKUP"

    UFW_BACKED_UP=true

    log "+" "original UFW state backed up"
}

# ---
# UFW KILL SWITCH
# ---

enable_killswitch() {

    backup_ufw

    sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true
    IPV6_MODIFIED=true

    if ! ufw --force enable >/dev/null 2>&1; then
        return 1
    fi

    UFW_MODIFIED=true

    if ! ufw default deny incoming >/dev/null 2>&1; then
        return 1
    fi

    if ! ufw default deny outgoing >/dev/null 2>&1; then
        return 1
    fi

    ufw default deny outgoing on ipv6 >/dev/null 2>&1 || true

    if ! ufw allow in on "$TUN_DEV" \
        from any to any >/dev/null 2>&1; then

        return 1
    fi

    if ! ufw allow out on "$TUN_DEV" \
        from any to any >/dev/null 2>&1; then

        return 1
    fi

    log "+" "UFW kill switch enabled"

    return 0
}

restore_ufw() {

    [ "$UFW_BACKED_UP" = true ] || return 0
    [ -f "$UFW_BACKUP" ] || return 0

    local status="$ORIGINAL_UFW_STATUS"
    local incoming="$ORIGINAL_UFW_IN"
    local outgoing="$ORIGINAL_UFW_OUT"

    ufw_remove_instance_rules

    ufw delete allow in on "$TUN_DEV" \
        from any to any >/dev/null 2>&1 || true

    ufw delete allow out on "$TUN_DEV" \
        from any to any >/dev/null 2>&1 || true

    ufw default "$incoming" incoming >/dev/null 2>&1 || true
    ufw default "$outgoing" outgoing >/dev/null 2>&1 || true

    ufw default allow outgoing on ipv6 >/dev/null 2>&1 || true

    if [ "$status" = "inactive" ]; then
        ufw disable >/dev/null 2>&1 || true
    else
        ufw reload >/dev/null 2>&1 || true
    fi

    if [ "$IPV6_MODIFIED" = true ]; then
        sysctl -w net.ipv6.conf.all.disable_ipv6="$ORIGINAL_IPV6_ALL" >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6="$ORIGINAL_IPV6_DEF" >/dev/null 2>&1 || true
        IPV6_MODIFIED=false
    fi

    rm -f "$UFW_BACKUP"

    UFW_BACKED_UP=false
    UFW_MODIFIED=false

    log "+" "original UFW state restored"
}

# ---
# VPN PROCESS
# ---

vpn_pid() {

    [ -f "$PID_FILE" ] || return 1

    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)

    [[ "$pid" =~ ^[0-9]+$ ]] || return 1

    printf '%s\n' "$pid"
}

vpn_is_ours() {

    local pid="$1"

    [ -d "/proc/$pid" ] || return 1

    [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = "openvpn" ]
}

kill_vpn() {

    local pid

    if pid=$(vpn_pid); then

        if vpn_is_ours "$pid"; then
            log "-" "stopping OpenVPN (PID $pid)"
            kill -TERM "$pid" >/dev/null 2>&1 || true

            for _ in {1..10}; do
                kill -0 "$pid" >/dev/null 2>&1 || break
                sleep 0.5
            done

            if kill -0 "$pid" >/dev/null 2>&1; then
                log "!" "OpenVPN did not terminate gracefully; sending SIGKILL"
                kill -KILL "$pid" >/dev/null 2>&1 || true
            fi
        fi
    fi

    rm -f "$PID_FILE"

    VPN_ACTIVE=false
}

# ---
# OPENVPN CONFIG PARSING
# ---

parse_proto() {

    local raw="$1"

    case "$raw" in
        tcp|tcp-client|tcp4)
            echo "tcp"
            ;;
        udp|udp4)
            echo "udp"
            ;;
        *)
            return 1
            ;;
    esac
}

# ---
# VPN ENDPOINT FIREWALL
# ---

allow_vpn_endpoints() {

    local config="$1"

    local global_proto
    local global_port

    global_proto=$(
        grep -m1 '^proto ' "$config" \
        | awk '{print $2}' \
        | tr -d '\r' \
        || true
    )

    global_port=$(
        grep -m1 '^port ' "$config" \
        | awk '{print $2}' \
        | tr -d '\r' \
        || true
    )

    [ -n "$global_port" ] || global_port=1194

    global_proto=$(parse_proto "$global_proto" 2>/dev/null || echo "udp")

    local found=false

    while read -r remote_line; do

        local host
        local port
        local proto

        host=$(awk '{print $2}' <<< "$remote_line")
        port=$(awk '{print $3}' <<< "$remote_line")
        proto=$(awk '{print $4}' <<< "$remote_line")

        [ -n "$host" ] || continue
        [ -n "$port" ] || port="$global_port"
        [ -n "$proto" ] || proto="$global_proto"

        if ! proto=$(parse_proto "$proto" 2>/dev/null); then
            log "!" "unsupported protocol '$proto' for $host"
            continue
        fi

        if ! [[ "$port" =~ ^[0-9]+$ ]] \
            || [ "$port" -lt 1 ] \
            || [ "$port" -gt 65535 ]; then

            log "!" "invalid port '$port' for $host"
            continue
        fi

        local ips

        ips=$(
            getent ahostsv4 "$host" \
            | awk '{print $1}' \
            | sort -u \
            || true
        )

        if [ -z "$ips" ]; then
            log "!" "unable to resolve VPN endpoint: $host"
            continue
        fi

        local ip

        while read -r ip; do

            [ -n "$ip" ] || continue

            if ! ufw allow out \
                to "$ip" \
                port "$port" \
                proto "$proto" \
                comment "$UFW_TAG" >/dev/null 2>&1; then

                log "!" "failed UFW rule: $ip:$port/$proto"
                continue
            fi

            found=true

            log "+" "allowed VPN endpoint $ip:$port/$proto"

        done <<< "$ips"

    done < <(
        grep '^remote ' "$config" \
        | tr -d '\r' \
        || true
    )

    [ "$found" = true ]
}

# ---
# START VPN
# ---

start_vpn() {

    local config="$1"

    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        log "!" "$TUN_DEV already exists"
        return 1
    fi

    rm -f "$PID_FILE"

    log "+" "starting OpenVPN: $config"

    if ! openvpn \
        --config "$config" \
        --auth-user-pass "$FILE_AUTH" \
        --daemon \
        --writepid "$PID_FILE" \
        --log "$LOG_FILE" \
        --dev "$TUN_DEV" \
        --dhcp-option DNS 9.9.9.9 \
        --dhcp-option DNS 1.1.1.1 \
        --pull-filter ignore "route-ipv6" \
        --pull-filter ignore "ifconfig-ipv6"
    then

        log "!" "OpenVPN failed to start"
        return 1
    fi

    VPN_ACTIVE=true

    return 0
}

# ---
# VERIFY TUNNEL
# ---

verify_vpn() {

    local pid

    if ! pid=$(vpn_pid); then
        log "!" "OpenVPN did not create a valid PID file"
        return 1
    fi

    if ! vpn_is_ours "$pid"; then
        log "!" "PID file does not belong to OpenVPN"
        return 1
    fi

    for _ in {1..20}; do

        if ! kill -0 "$pid" >/dev/null 2>&1; then
            log "!" "OpenVPN died during startup"
            return 1
        fi

        if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
            sleep 1
            continue
        fi

        if ! ip route get 8.8.8.8 2>/dev/null \
            | grep -q "dev $TUN_DEV"; then

            sleep 1
            continue
        fi

        if ! configure_tunnel_dns; then
            log "!" "DNS configuration on tunnel failed"
            return 1
        fi

        local ip_check_success=false
        for url in "${IP_CHECK_URLS[@]}"; do
            if curl \
                --silent \
                --show-error \
                --connect-timeout 3 \
                --max-time 7 \
                --interface "$TUN_DEV" \
                "$url" \
                >/dev/null 2>&1; then
                ip_check_success=true
                break
            fi
        done

        if [ "$ip_check_success" = true ]; then
            return 0
        fi

        sleep 1
    done

    return 1
}

# ---
# CLEANUP
# ---

cleanup() {

    if [ "$CLEANED_UP" = true ]; then
        return
    fi

    CLEANED_UP=true

    echo
    log "!" "cleaning up"

    kill_vpn

    ufw_remove_instance_rules

    restore_ufw
    restore_dns

    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        ip link delete "$TUN_DEV" >/dev/null 2>&1 || true
    fi

    rm -f "$PID_FILE"

    log "+" "cleanup completed"

    exit 0
}

trap cleanup EXIT INT TERM

# ---
# RESET
# ---

reset_state() {

    check_root

    echo "[!] emergency reset requested"

    for number in $(
        ufw status numbered \
        | grep "$UFW_FAMILY-" \
        | awk -F'[][]' '{print $2}' \
        | sort -nr \
        || true
    ); do

        yes | ufw delete "$number" >/dev/null 2>&1 || true
    done


    if [ -f "$UFW_BACKUP" ]; then
        log "+" "UFW backup found; attempting restoration"

        while IFS='=' read -r key value; do
            case "$key" in
                status)   ORIGINAL_UFW_STATUS="$value" ;;
                incoming) ORIGINAL_UFW_IN="$value" ;;
                outgoing) ORIGINAL_UFW_OUT="$value" ;;
                ipv6_all) ORIGINAL_IPV6_ALL="$value" ;;
                ipv6_def) ORIGINAL_IPV6_DEF="$value" ;;
            esac
        done < "$UFW_BACKUP"

        UFW_BACKED_UP=true
        UFW_MODIFIED=true
        IPV6_MODIFIED=true

        restore_ufw
    fi

    if [ -f "$DNS_BACKUP" ]; then
    if cat "$DNS_BACKUP" > /etc/resolv.conf 2>/dev/null; then
            rm -f "$DNS_BACKUP"
            log "+" "DNS backup restored"
        else
            log "!" "could not restore DNS backup"
        fi
    fi

    if ip link show "$TUN_DEV" >/dev/null 2>&1; then
        ip link delete "$TUN_DEV" >/dev/null 2>&1 || true
    fi

    rm -f "$PID_FILE"

    echo "[+] reset completed"
}

# ---
# MAIN
# ---

check_root

if [ "${1:-}" = "--reset" ]; then
    reset_state
    exit 0
fi

check_dependencies
acquire_lock

FOLDER_VPNS=$(realpath "$FOLDER_VPNS") \
    || die "unable to resolve VPN directory"

FILE_AUTH=$(realpath "$FILE_AUTH") \
    || die "unable to resolve credentials file"

validate_environment

cd "$FOLDER_VPNS" \
    || die "unable to enter VPN directory"

shopt -s nullglob

vpns=( *.ovpn )

[ "${#vpns[@]}" -gt 0 ] \
    || die "no .ovpn files found"

# ---
# PREPARE SYSTEM
# ---

if ! enable_killswitch; then
    die "failed to configure UFW kill switch"
fi

backup_dns
configure_dns

log "+" "system protection enabled"
log "i" "press Ctrl+C to stop and restore the system"

echo "------------------------------------------------------------"

# ---
# ROTATION
# ---

last_config=""

while true; do

    allowed=false

    if [ "${#vpns[@]}" -gt 1 ]; then
        while true; do
            index=$((RANDOM % ${#vpns[@]}))
            config="${vpns[$index]}"

            [ "$config" != "$last_config" ] && break
        done
    else
        config="${vpns[0]}"
    fi

    CURRENT_CONFIG="$config"
    last_config="$config"

    log "+" "selected VPN: $config"

    ufw_remove_instance_rules

    if ! allow_vpn_endpoints "$config"; then
        log "!" "no valid VPN endpoints found; trying another configuration"
        sleep 2
        continue
    fi

    if ! start_vpn "$config"; then
        ufw_remove_instance_rules
        sleep 2
        continue
    fi

    if ! verify_vpn; then

        log "!" "VPN verification failed; rotating"

        kill_vpn
        ufw_remove_instance_rules

        sleep 2
        echo "------------------------------------------------------------"

        continue
    fi

    current_ip="unknown"
    for url in "${IP_CHECK_URLS[@]}"; do
        current_ip=$(
            curl \
                --silent \
                --connect-timeout 3 \
                --max-time 7 \
                --interface "$TUN_DEV" \
                "$url" \
                2>/dev/null
        )
        if [ -n "$current_ip" ]; then
            break
        fi
    done
    [ -z "$current_ip" ] && current_ip="unknown"

    log "+" "VPN active"
    log "+" "public IP: $current_ip"
    log "+" "holding connection for ${TEMPO}s"

    sleep "$TEMPO"

    log "-" "rotation interval completed"

    kill_vpn

    sleep 2

    ufw_remove_instance_rules

    echo "------------------------------------------------------------"
done
