#!/usr/bin/env bash

yba_is_local_host() {
    local host=${1:-}
    [ -z "$host" ] || [ "$host" = "localhost" ] || [ "$host" = "127.0.0.1" ] || [ "$host" = "$(hostname)" ]
}

yba_host_role() {
    local host=$1
    if [ "$host" = "${SERVER_HOST:-}" ]; then
        echo server
    elif [ "$host" = "${CLIENT_HOST:-}" ]; then
        echo client
    else
        echo other
    fi
}

yba_split_words() {
    local value=${1:-}
    local -n out_ref=$2
    out_ref=()
    [ -n "$value" ] || return 0
    # Configured option strings are shell-style snippets, e.g. "-F path -p 2222".
    eval "out_ref=( $value )"
}

yba_ssh_args_for_host() {
    local host=$1
    local -n out_ref=$2
    local role role_opts=() global_opts=()
    role=$(yba_host_role "$host")
    yba_split_words "$SSH_OPTS" global_opts
    case "$role" in
        server) yba_split_words "$SERVER_SSH_OPTS" role_opts ;;
        client) yba_split_words "$CLIENT_SSH_OPTS" role_opts ;;
        *) role_opts=() ;;
    esac
    out_ref=("${global_opts[@]}" "${role_opts[@]}")
}

yba_scp_args_for_host() {
    local host=$1
    local -n out_ref=$2
    local role role_opts=() global_opts=()
    role=$(yba_host_role "$host")
    yba_split_words "$SCP_OPTS" global_opts
    case "$role" in
        server) yba_split_words "${SERVER_SCP_OPTS:-$SERVER_SSH_OPTS}" role_opts ;;
        client) yba_split_words "${CLIENT_SCP_OPTS:-$CLIENT_SSH_OPTS}" role_opts ;;
        *) role_opts=() ;;
    esac
    out_ref=("${global_opts[@]}" "${role_opts[@]}")
}

yba_ssh_cmd_for_host() {
    local host=$1
    local args=() quoted=()
    yba_ssh_args_for_host "$host" args
    local arg
    for arg in "${args[@]}"; do
        quoted+=("$(yba_quote "$arg")")
    done
    echo "$SSH_BIN ${quoted[*]}"
}

yba_rsync_rsh_for_host() {
    local host=$1
    local role specific
    role=$(yba_host_role "$host")
    case "$role" in
        server) specific=${SERVER_RSYNC_RSH:-} ;;
        client) specific=${CLIENT_RSYNC_RSH:-} ;;
        *) specific= ;;
    esac
    if [ -n "$specific" ]; then
        echo "$specific"
    elif [ -n "$RSYNC_RSH" ]; then
        echo "$RSYNC_RSH"
    else
        yba_ssh_cmd_for_host "$host"
    fi
}

yba_host_run() {
    local host=$1
    shift
    if yba_is_local_host "$host"; then
        bash -lc "$*"
    else
        local args=()
        yba_ssh_args_for_host "$host" args
        "$SSH_BIN" -o StrictHostKeyChecking=no "${args[@]}" "$host" "$*"
    fi
}

yba_host_copy_to() {
    local src=$1
    local host=$2
    local dst=$3
    if yba_is_local_host "$host"; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
    else
        local ssh_args=() scp_args=()
        yba_ssh_args_for_host "$host" ssh_args
        yba_scp_args_for_host "$host" scp_args
        "$SSH_BIN" -o StrictHostKeyChecking=no "${ssh_args[@]}" "$host" "mkdir -p '$(dirname "$dst")'"
        "$SCP_BIN" -q "${scp_args[@]}" "$src" "${host}:${dst}"
    fi
}

yba_host_rsync_from() {
    local host=$1
    local src=$2
    local dst=$3
    mkdir -p "$dst"
    if yba_is_local_host "$host"; then
        "$RSYNC_BIN" -a "$src/" "$dst/"
    else
        local rsh
        rsh=$(yba_rsync_rsh_for_host "$host")
        # shellcheck disable=SC2086
        "$RSYNC_BIN" -a $RSYNC_OPTS -e "$rsh" "${host}:${src}/" "$dst/"
    fi
}

yba_remote_env_prefix() {
    cat <<EOF
YBA_ROOT=$(yba_quote "$REMOTE_ROOT") \
REMOTE_MODE=1 \
DB_TYPE=$(yba_quote "$DB_TYPE") \
MODE=$(yba_quote "$MODE") \
SERVER_HOST=$(yba_quote "$SERVER_HOST") \
CLIENT_HOST=$(yba_quote "$CLIENT_HOST") \
REMOTE_ROOT=$(yba_quote "$REMOTE_ROOT") \
EXPERIMENT_DIR=$(yba_quote "$REMOTE_EXPERIMENT_DIR") \
YCSB_HOME=$(yba_quote "$YCSB_HOME") \
PYTHON2_BIN=$(yba_quote "$PYTHON2_BIN") \
PYTHON2_LD_LIBRARY_PATH=$(yba_quote "$PYTHON2_LD_LIBRARY_PATH") \
JDBC_URL=$(yba_quote "$JDBC_URL") \
JDBC_USER=$(yba_quote "$JDBC_USER") \
JDBC_PASSWORD=$(yba_quote "$JDBC_PASSWORD") \
JDBC_DRIVER=$(yba_quote "$JDBC_DRIVER") \
JDBC_JAR=$(yba_quote "$JDBC_JAR") \
DB_PROPS=$(yba_quote "$DB_PROPS") \
TABLE=$(yba_quote "$TABLE") \
WORKLOAD_FILE=$(yba_quote "$WORKLOAD_FILE") \
GENERATE_WORKLOAD=$(yba_quote "$GENERATE_WORKLOAD") \
GENERATED_WORKLOAD=$(yba_quote "$GENERATED_WORKLOAD") \
RECORDCOUNT=$(yba_quote "$RECORDCOUNT") \
OPERATIONCOUNT_PER_CLIENT=$(yba_quote "$OPERATIONCOUNT_PER_CLIENT") \
REQUEST_DISTRIBUTION=$(yba_quote "$REQUEST_DISTRIBUTION") \
READ_PROPORTION=$(yba_quote "$READ_PROPORTION") \
UPDATE_PROPORTION=$(yba_quote "$UPDATE_PROPORTION") \
SCAN_PROPORTION=$(yba_quote "$SCAN_PROPORTION") \
INSERT_PROPORTION=$(yba_quote "$INSERT_PROPORTION") \
INSERT_ORDER=$(yba_quote "$INSERT_ORDER") \
MATRIX=$(yba_quote "$MATRIX") \
ROUNDS=$(yba_quote "$ROUNDS") \
STATUS_INTERVAL=$(yba_quote "$STATUS_INTERVAL") \
RUN_SECONDS=$(yba_quote "$RUN_SECONDS") \
ENABLE_CGROUP=$(yba_quote "$ENABLE_CGROUP") \
CGROUP_ROOT=$(yba_quote "$CGROUP_ROOT") \
SERVER_CGROUP=$(yba_quote "$SERVER_CGROUP") \
CLIENT_CGROUP=$(yba_quote "$CLIENT_CGROUP") \
SERVER_CPUSET_EXPECT=$(yba_quote "$SERVER_CPUSET_EXPECT") \
SERVER_MEMS_EXPECT=$(yba_quote "$SERVER_MEMS_EXPECT") \
CLIENT_CPUSET_EXPECT=$(yba_quote "$CLIENT_CPUSET_EXPECT") \
CLIENT_MEMS_EXPECT=$(yba_quote "$CLIENT_MEMS_EXPECT") \
CGROUP_AUTO_CONFIG=$(yba_quote "$CGROUP_AUTO_CONFIG") \
CGROUP_WRITE_WITH_SUDO=$(yba_quote "$CGROUP_WRITE_WITH_SUDO") \
CGROUP_PROCS_WRITE_WITH_SUDO=$(yba_quote "$CGROUP_PROCS_WRITE_WITH_SUDO") \
CGROUP_PROCS_SMOKE_TEST=$(yba_quote "$CGROUP_PROCS_SMOKE_TEST") \
SUDO_ASKPASS=$(yba_quote "$SUDO_ASKPASS") \
ENABLE_THREAD_CLUSTER=$(yba_quote "$ENABLE_THREAD_CLUSTER") \
THREAD_CLUSTER_RULES=$(yba_quote "$THREAD_CLUSTER_RULES") \
SERVER_PID_COMMAND=$(yba_quote "$SERVER_PID_COMMAND") \
DORIS_HOME=$(yba_quote "$DORIS_HOME") \
DORIS_START_FE=$(yba_quote "$DORIS_START_FE") \
DORIS_START_BE=$(yba_quote "$DORIS_START_BE") \
DORIS_STOP_FE=$(yba_quote "$DORIS_STOP_FE") \
DORIS_STOP_BE=$(yba_quote "$DORIS_STOP_BE") \
DORIS_READY_CMD=$(yba_quote "$DORIS_READY_CMD") \
DORIS_SWAP_CHECK=$(yba_quote "$DORIS_SWAP_CHECK") \
DORIS_SWAPOFF_WITH_SUDO=$(yba_quote "$DORIS_SWAPOFF_WITH_SUDO") \
DORIS_PROC_SWAPS=$(yba_quote "$DORIS_PROC_SWAPS") \
CLICKHOUSE_HOME=$(yba_quote "$CLICKHOUSE_HOME") \
SERVER_SETUP_CMD=$(yba_quote "$SERVER_SETUP_CMD") \
SERVER_CLEANUP_CMD=$(yba_quote "$SERVER_CLEANUP_CMD") \
SERVER_READY_CMD=$(yba_quote "$SERVER_READY_CMD") \
SERVER_READY_TIMEOUT=$(yba_quote "$SERVER_READY_TIMEOUT") \
SERVER_READY_INTERVAL=$(yba_quote "$SERVER_READY_INTERVAL") \
CLEANUP_SERVER=$(yba_quote "$CLEANUP_SERVER") \
SERVER_WARNING_LOG_GLOB=$(yba_quote "$SERVER_WARNING_LOG_GLOB") \
ENABLE_NODE_CPU_SAMPLER=$(yba_quote "$ENABLE_NODE_CPU_SAMPLER") \
ENABLE_VMSTAT=$(yba_quote "$ENABLE_VMSTAT") \
ENABLE_NUMASTAT=$(yba_quote "$ENABLE_NUMASTAT")
EOF
}
