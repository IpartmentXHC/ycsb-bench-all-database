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
            yba_clickhouse_start
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
            yba_clickhouse_stop
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
    if [ -n "${SERVER_SETUP_CMD:-}" ]; then
        return 0
    fi
    test -x "$CLICKHOUSE_BIN" || yba_die "missing executable CLICKHOUSE_BIN: $CLICKHOUSE_BIN"
    test -x "$CLICKHOUSE_CLIENT" || yba_die "missing executable CLICKHOUSE_CLIENT: $CLICKHOUSE_CLIENT"
    test -f "$CLICKHOUSE_CONFIG" || yba_die "missing CLICKHOUSE_CONFIG: $CLICKHOUSE_CONFIG"
    case "$CLICKHOUSE_MODE" in
        unrestricted|node1|nodes:*) ;;
        *) yba_die "CLICKHOUSE_MODE must be unrestricted, node1, or nodes:<comma-list>, got: $CLICKHOUSE_MODE" ;;
    esac
    if [ "$CLICKHOUSE_MODE" != "unrestricted" ]; then
        command -v numactl >/dev/null 2>&1 || yba_die "numactl is required for CLICKHOUSE_MODE=$CLICKHOUSE_MODE"
    fi
}

yba_clickhouse_numactl_prefix() {
    local mode=${1:-$CLICKHOUSE_MODE}
    local nodes
    case "$mode" in
        unrestricted)
            return 0
            ;;
        node1)
            printf 'numactl --cpunodebind=%s --membind=%s' "$CLICKHOUSE_NUMA_NODE" "$CLICKHOUSE_NUMA_NODE"
            ;;
        nodes:*)
            nodes=${mode#nodes:}
            [[ "$nodes" =~ ^[0-9]+(,[0-9]+)*$ ]] || yba_die "invalid CLICKHOUSE_MODE=$mode; expected nodes:<comma-separated-node-ids>"
            printf 'numactl --cpunodebind=%s --membind=%s' "$nodes" "$nodes"
            ;;
        *)
            yba_die "CLICKHOUSE_MODE must be unrestricted, node1, or nodes:<comma-list>, got: $mode"
            ;;
    esac
}

yba_clickhouse_pids() {
    local escaped_config
    escaped_config=$(printf '%s\n' "$CLICKHOUSE_CONFIG" | sed 's/[][\.^$*+?{}()|/]/\\&/g')
    pgrep -f "clickhouse[[:space:]]+server.*--config-file=${escaped_config}" 2>/dev/null || true
}

yba_clickhouse_start() {
    local prefix
    yba_clickhouse_preflight
    mkdir -p "$CLICKHOUSE_LOG_DIR"
    yba_clickhouse_stop
    prefix=$(yba_clickhouse_numactl_prefix "$CLICKHOUSE_MODE")
    if [ -n "$prefix" ]; then
        yba_log "starting ClickHouse with $prefix"
        # shellcheck disable=SC2086
        nohup $prefix "$CLICKHOUSE_BIN" server --config-file="$CLICKHOUSE_CONFIG" \
            >"$CLICKHOUSE_LOG_DIR/clickhouse-${CLICKHOUSE_MODE}.out" \
            2>"$CLICKHOUSE_LOG_DIR/clickhouse-${CLICKHOUSE_MODE}.err" &
    else
        yba_log "starting ClickHouse unrestricted"
        nohup "$CLICKHOUSE_BIN" server --config-file="$CLICKHOUSE_CONFIG" \
            >"$CLICKHOUSE_LOG_DIR/clickhouse-${CLICKHOUSE_MODE}.out" \
            2>"$CLICKHOUSE_LOG_DIR/clickhouse-${CLICKHOUSE_MODE}.err" &
    fi
    disown
}

yba_clickhouse_stop() {
    local pids pid i
    pids=$(yba_clickhouse_pids)
    if [ -z "$pids" ]; then
        yba_log "no ClickHouse server for config: $CLICKHOUSE_CONFIG"
        return 0
    fi
    yba_log "stopping ClickHouse pids: $pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    for i in $(seq 1 30); do
        sleep 1
        if [ -z "$(yba_clickhouse_pids)" ]; then
            return 0
        fi
    done
    for pid in $pids; do
        kill -KILL "$pid" 2>/dev/null || true
    done
}
