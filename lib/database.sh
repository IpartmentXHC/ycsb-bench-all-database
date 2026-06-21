#!/usr/bin/env bash

yba_database_preflight_server() {
    case "$DB_TYPE" in
        doris)
            yba_doris_preflight
            ;;
        clickhouse)
            yba_clickhouse_preflight
            ;;
        *)
            yba_die "DB_TYPE must be doris or clickhouse, got: $DB_TYPE"
            ;;
    esac
}

yba_database_setup_server() {
    if [ -n "$SERVER_SETUP_CMD" ]; then
        if [ "$DB_TYPE" = "doris" ]; then
            yba_doris_check_swap
        fi
        yba_log "server setup hook"
        bash -lc "$SERVER_SETUP_CMD"
        return 0
    fi
    case "$DB_TYPE" in
        doris)
            yba_doris_start
            ;;
        clickhouse)
            yba_die "ClickHouse default start is not configured; set SERVER_SETUP_CMD for now"
            ;;
        *)
            yba_die "DB_TYPE must be doris or clickhouse, got: $DB_TYPE"
            ;;
    esac
}

yba_database_cleanup_server() {
    if [ "$CLEANUP_SERVER" != "1" ]; then
        return 0
    fi
    if [ -n "$SERVER_CLEANUP_CMD" ]; then
        yba_log "server cleanup hook"
        bash -lc "$SERVER_CLEANUP_CMD" || true
        return 0
    fi
    case "$DB_TYPE" in
        doris)
            yba_doris_stop
            ;;
        clickhouse)
            return 0
            ;;
    esac
}

yba_doris_preflight() {
    if [ -n "${SERVER_SETUP_CMD:-}" ]; then
        yba_doris_check_swap
        return 0
    fi
    test -x "$DORIS_START_FE" || yba_die "missing executable DORIS_START_FE: $DORIS_START_FE"
    test -x "$DORIS_START_BE" || yba_die "missing executable DORIS_START_BE: $DORIS_START_BE"
    yba_doris_check_swap
}

yba_doris_swap_enabled() {
    local swaps=${DORIS_PROC_SWAPS:-/proc/swaps}
    [ -r "$swaps" ] || return 1
    awk 'NR > 1 && $1 != "" {found=1} END {exit found ? 0 : 1}' "$swaps"
}

yba_doris_check_swap() {
    [ "${DORIS_SWAP_CHECK:-1}" = "1" ] || return 0
    if ! yba_doris_swap_enabled; then
        return 0
    fi
    if [ "${DORIS_SWAPOFF_WITH_SUDO:-0}" = "1" ]; then
        yba_log "Doris requires swap disabled; running sudo swapoff -a"
        if [ -n "${SUDO_ASKPASS:-}" ]; then
            SUDO_ASKPASS="$SUDO_ASKPASS" sudo -A swapoff -a
        else
            sudo swapoff -a
        fi
        return 0
    fi
    cat >&2 <<'EOF'
ERROR: swap is enabled, but Doris BE requires swap to be disabled.
Run this once after boot, or set DORIS_SWAPOFF_WITH_SUDO=1 if yba may use sudo:
  sudo swapoff -a
This tool does not edit /etc/fstab, so the change is not persistent across reboot.
EOF
    return 1
}

yba_doris_start() {
    yba_doris_preflight
    yba_log "starting Doris FE"
    sh "$DORIS_START_FE" --daemon
    yba_log "starting Doris BE"
    sh "$DORIS_START_BE" --daemon
}

yba_doris_stop() {
    yba_log "stopping Doris BE/FE"
    if [ -x "$DORIS_STOP_BE" ]; then
        sh "$DORIS_STOP_BE" --daemon 2>/dev/null || true
    fi
    if [ -x "$DORIS_STOP_FE" ]; then
        sh "$DORIS_STOP_FE" --daemon 2>/dev/null || true
    fi
}

yba_clickhouse_preflight() {
    if [ -z "${SERVER_SETUP_CMD:-}" ]; then
        yba_die "ClickHouse support is a template in this version; set SERVER_SETUP_CMD and SERVER_READY_CMD"
    fi
}
